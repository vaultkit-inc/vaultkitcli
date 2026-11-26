# frozen_string_literal: true

require "json"

module Vkit
  module CLI
    module Commands
      class ScanCommand < BaseCommand
        def call(datasource_name, mode: "diff_only")
          with_auth do
            user = credential_store.user
            org  = user["organization_slug"]

            puts "🔍 Scanning #{datasource_name}..."
            puts

            response = authenticated_client.post(
              "/api/v1/orgs/#{org}/datasources/#{datasource_name}/scan",
              body: { datasource: datasource_name, mode: mode }
            )

            print_diff(response)
            respond(json_result(org, datasource_name, mode, response), scan_next_steps(datasource_name, mode)) if json?
          end
        end

        private

        # Every column of the scanned datasets, for review: the registry as
        # the control plane has it, with the scan's changes on top (the diff
        # only lists what changed). unknown: the classifier couldn't place
        # it; unreviewed: nobody has set it yet (the starter pack masks those
        # for agents).
        def json_result(org, datasource, mode, response)
          datasets = Array(response.dig("diff", "datasets"))
          registry = registry_export(org)

          {
            "datasource" => datasource,
            "mode" => mode,
            "applied" => response["applied"] == true,
            # Nothing to change: control planes from vaultkit#126 on say so
            # (a setup token's apply on a set-up organization is then a no-op,
            # not refused); older ones only by an empty diff.
            "unchanged" => response["unchanged"] == true ||
                           datasets.none? { |d| (d["changes"] || {}).values.any? { |v| Array(v).any? } },
            "scan_id" => response["scan_id"],
            "columns_complete" => !registry.nil?,
            "datasets" => datasets.map { |d| json_dataset(d, registry && registry[d["name"]]) },
            "unreviewed_count" => datasets.sum { |d| unreviewed_for(d).size },
            "suggestion_count" => datasets.sum { |d| suggestions_for(d).size }
          }.compact
        end

        def registry_export(org)
          export = authenticated_client.get("/api/v1/orgs/#{org}/registries/export")
          export.is_a?(Hash) ? export : nil
        rescue StandardError => e
          warn "⚠️  Couldn't read the registry (#{e.message}); listing only the columns that changed."
          nil
        end

        def json_dataset(dataset, registered)
          changes = dataset["changes"] || {}
          columns = {}

          (registered && registered["fields"] || {}).each do |name, f|
            columns[name] = column(name, f["type"], f["sensitivity"], f["category"])
          end
          Array(changes["added_fields"]).each do |f|
            f = { "name" => f } unless f.is_a?(Hash)
            columns[f["name"]] = column(f["name"], f["type"], f["sensitivity"], Array(f["tags"]).first, "added")
          end
          Array(changes["changed_fields"]).each do |f|
            f = { "name" => f } unless f.is_a?(Hash)
            to = f["to"] || {}
            columns[f["name"]] = column(f["name"], to["type"], to["sensitivity"], Array(to["tags"]).first, "changed")
          end
          Array(changes["removed_fields"]).each do |f|
            name = f.is_a?(Hash) ? f["name"] : f
            columns[name] = (columns[name] || column(name, nil, nil, nil)).merge("change" => "removed")
          end

          unreviewed = unreviewed_for(dataset)
          suggestions = suggestions_for(dataset).to_h { |s| [s["name"], s] }
          unreviewed.each { |name| columns[name] ||= column(name, nil, "unknown", nil) }
          suggestions.each_key { |name| columns[name] ||= column(name, nil, nil, nil) }

          {
            "name" => dataset["name"],
            "changed" => changes.values.any? { |v| Array(v).any? },
            "columns" => columns.values.map do |c|
              c.merge("unreviewed" => unreviewed.include?(c["name"]),
                      "unknown" => c["sensitivity"] == "unknown" || unreviewed.include?(c["name"]),
                      "suggestion" => suggestion(suggestions[c["name"]]))
            end
          }
        end

        def column(name, type, sensitivity, category, change = nil)
          { "name" => name, "type" => type, "sensitivity" => sensitivity, "category" => category, "change" => change }
        end

        def suggestion(s)
          return nil unless s

          {
            "current" => classification(s["current"]),
            "suggested" => classification(s["suggested"])
          }
        end

        def classification(c)
          c ||= {}
          { "sensitivity" => c["sensitivity"], "category" => Array(c["tags"]).first, "tags" => Array(c["tags"]) }
        end

        def scan_next_steps(datasource, mode)
          if mode == "apply"
            # Between the two: review datasets/registry.yaml (each unknown
            # column's sensitivity) and commit it.
            ["vkit registry export --force --format json", "vkit policy bundle --format json"]
          else
            ["vkit scan #{datasource} --mode apply --format json"]
          end
        end

        def print_diff(response)
          diff     = response["diff"] || {}
          datasets = diff["datasets"] || []
          changed  = datasets.select { |d| d["changes"].values.any?(&:any?) }
          clean    = datasets.reject { |d| d["changes"].values.any?(&:any?) }

          if changed.empty?
            datasets.each { |d| print_clean(d) }
            puts
            puts "  No changes detected"
          else
            changed.each do |dataset|
              added    = dataset.dig("changes", "added_fields")   || []
              removed  = dataset.dig("changes", "removed_fields") || []
              modified = dataset.dig("changes", "changed_fields") || []

              puts "  #{dataset["name"]}"

              added.each do |f|
                name = f.is_a?(Hash) ? f["name"] : f
                type = f.is_a?(Hash) && f["type"] ? " (#{f["type"]})" : ""
                puts "    + #{name}#{type}  ⚠️  unclassified"
              end

              removed.each do |f|
                name = f.is_a?(Hash) ? f["name"] : f
                puts "    - #{name}"
              end

              modified.each do |f|
                name = f.is_a?(Hash) ? f["name"] : f
                puts "    ~ #{name}"
              end

              print_suggestions(dataset)
              print_unreviewed(dataset)

              puts
            end

            clean.each { |d| print_clean(d) }

            puts
            puts "  #{changed.size} changed · run with --mode apply to update baseline"
          end

          # Suggestions are reviewed labels the classifier now disagrees with.
          # Older control planes don't send them; applying a scan never changes them.
          if datasets.any? { |d| suggestions_for(d).any? }
            puts
            puts "  ? = classifier suggestion, not applied. To accept one, edit"
            puts "    datasets/registry.yaml and redeploy the bundle."
          end

          print_unreviewed_note(datasets)

          puts
          puts "  ✅ Applied" if response["applied"]
        end

        def print_clean(dataset)
          puts "  #{dataset["name"].ljust(24)} ✓"
          print_suggestions(dataset)
          print_unreviewed(dataset)
        end

        # Columns still labelled unknown. Older control planes don't send them.
        # The starter pack masks them for agents until someone reviews them.
        def print_unreviewed(dataset)
          names = unreviewed_for(dataset)
          puts "    ! unreviewed: #{names.join(", ")}" if names.any?
        end

        def print_unreviewed_note(datasets)
          count = datasets.sum { |d| unreviewed_for(d).size }
          return if count.zero?

          puts
          puts "  ⚠️  #{count} #{count == 1 ? "column is" : "columns are"} unreviewed and masked until you review them"
          puts "     (for agents, under the starter pack). To review, set each one's sensitivity"
          puts "     in datasets/registry.yaml, then run: vkit policy bundle && vkit policy deploy"
        end

        def unreviewed_for(dataset)
          Array(dataset["unreviewed"])
        end

        def print_suggestions(dataset)
          suggestions_for(dataset).each do |s|
            puts "    ? #{s["name"]}  #{label(s["current"])} → #{label(s["suggested"])} (suggested)"
          end
        end

        def suggestions_for(dataset)
          dataset["suggestions"] || []
        end

        def label(classification)
          classification ||= {}
          tags = Array(classification["tags"])
          [classification["sensitivity"], *(tags.join(",") unless tags.empty?)].compact.join("/")
        end
      end
    end
  end
end

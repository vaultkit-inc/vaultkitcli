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
          end
        end

        private

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

          puts
          puts "  ✅ Applied" if response["applied"]
        end

        def print_clean(dataset)
          puts "  #{dataset["name"].ljust(24)} ✓"
          print_suggestions(dataset)
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

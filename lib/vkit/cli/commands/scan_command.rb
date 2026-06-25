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

            diff     = response["diff"] || {}
            datasets = diff["datasets"] || []
            changed  = datasets.select { |d| d["changes"].values.any?(&:any?) }
            clean    = datasets.reject { |d| d["changes"].values.any?(&:any?) }

            if changed.empty?
              datasets.each { |d| puts "  #{d["name"].ljust(24)} ✓" }
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

                puts
              end

              clean.each { |d| puts "  #{d["name"].ljust(24)} ✓" }

              puts
              puts "  #{changed.size} changed · run with --apply to update baseline"
            end

            puts
            puts "  ✅ Applied" if response["applied"]
          end
        end
      end
    end
  end
end

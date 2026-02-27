# frozen_string_literal: true

require "yaml"
require "json"
require_relative "../../core/registry_diff"
require_relative "../../core/registry_diff_printer"

module Vkit
  module CLI
    module Commands
      class RegistryDiffCommand < BaseCommand
        DEFAULT_PATH = File.join("datasets", "registry.yaml")

        def call(dir:, format: "human")
          ensure_project!(dir)

          dir  = File.expand_path(dir)
          path = File.join(dir, DEFAULT_PATH)

          unless File.exist?(path)
            puts "❌ No local registry.yaml found."
            exit 2
          end

          with_auth do
            user = credential_store.user
            org  = user["organization_slug"]

            local = YAML.safe_load(
              File.read(path),
              permitted_classes: [],
              permitted_symbols: [],
              aliases: false
            )
            runtime = authenticated_client.get(
              "/api/v1/orgs/#{org}/registries/export"
            )

            diff = Vkit::Core::RegistryDiff.compute(
              local: local,
              remote: runtime
            )

            if format == "json"
              puts JSON.pretty_generate(diff)
              exit diff["datasets"].empty? ? 0 : 1
            else
              Vkit::Core::RegistryDiffPrinter.print(diff)
              exit diff["datasets"].empty? ? 0 : 1
            end
          end

        rescue StandardError => e
          puts "❌ Error: #{e.message}"
          exit 2
        end

        private

        def ensure_project!(dir)
          raise "Not a VaultKit project (missing .vkit/)" unless Dir.exist?(File.join(dir, ".vkit"))
        end
      end
    end
  end
end

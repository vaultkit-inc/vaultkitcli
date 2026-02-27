# frozen_string_literal: true

require "yaml"
require_relative "base_command"

module Vkit
  module CLI
    module Commands
      class RegistryExportCommand < BaseCommand
        DEFAULT_PATH = File.join("datasets", "registry.yaml")

        def call(dir:, out: nil, force: false)
          with_auth do
            ensure_project!(dir)

            dir = File.expand_path(dir)
            path = out ? File.expand_path(out, dir) : File.join(dir, DEFAULT_PATH)

            if File.exist?(path) && !force
              decision = handle_existing_registry(dir: dir, path: path)
              return if decision == :abort
            end            

            user = credential_store.user
            org  = user["organization_slug"]

            registry_data = authenticated_client.get(
              "/api/v1/orgs/#{org}/registries/export"
            )

            FileUtils.mkdir_p(File.dirname(path))
            File.write(path, registry_data.to_yaml)

            puts "✅ Registry exported to:"
            puts "   #{relative(dir, path)}"
          end
        rescue StandardError => e
          puts "❌ Error: #{e.message}"
          exit 1
        end

        private

        def ensure_project!(dir)
          raise "Not a VaultKit project (missing .vkit/)" unless Dir.exist?(File.join(dir, ".vkit"))
        end

        def handle_existing_registry(dir:, path:)
          puts "\n⚠️  Existing registry.yaml detected at:"
          puts "   #{relative(dir, path)}\n\n"
        
          puts "Choose an option:"
          puts "  1) Overwrite entirely"
          puts "  2) Show diff"
          puts "  3) Abort"
          print "\nEnter choice [1-3]: "
        
          choice = STDIN.gets&.strip
        
          case choice
          when "1"
            puts "\nOverwriting existing registry..."
            :overwrite
        
          when "2"
            show_diff(dir: dir)
            puts "\nAborting."
            :abort
        
          else
            puts "\nAborting."
            :abort
          end
        end        

        def relative(root, abs)
          abs.sub(root + File::SEPARATOR, "")
        end

        def show_diff(dir:)
          Vkit::CLI::Commands::RegistryDiffCommand.new.call(dir: dir)
        end        
      end
    end
  end
end

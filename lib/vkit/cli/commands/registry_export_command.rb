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

            existed = File.exist?(path)
            if existed && !force
              overwrite_needed!(dir, path) if json?

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

            respond(
              { "path" => path, "overwritten" => existed,
                "datasets" => registry_data.is_a?(Hash) ? registry_data.keys.sort : [] },
              # After reviewing datasets/registry.yaml and committing it.
              ["git add datasets/registry.yaml && git commit -m \"Review VaultKit registry\"",
               "vkit policy bundle --format json"]
            )
          end
        rescue StandardError => e
          raise if json?

          puts "❌ Error: #{e.message}"
          exit 1
        end

        private

        def ensure_project!(dir)
          raise not_a_project if json? && !Dir.exist?(File.join(dir, ".vkit"))
          raise "Not a VaultKit project (missing .vkit/)" unless Dir.exist?(File.join(dir, ".vkit"))
        end

        def not_a_project
          Vkit::CLI::CommandError.new("Not a VaultKit project (missing .vkit/)", code: "not_a_project",
                                      fix: ["Run `vkit init` first, or pass --dir <project>."])
        end

        # Overwriting replaces any review already done in the file, so it's
        # the person's call (vkit init's placeholder file included).
        def overwrite_needed!(dir, path)
          needs_input!("overwrite_confirmation_required",
                       "#{relative(dir, path)} already exists and exporting would replace it.",
                       ["Check `vkit registry diff --format json`; if replacing the file is fine " \
                        "(it's still vkit init's placeholder, or the person agrees), rerun with --force."],
                       next_steps: ["vkit registry diff --format json"])
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

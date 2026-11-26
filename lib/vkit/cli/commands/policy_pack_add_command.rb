# frozen_string_literal: true

require_relative "base_command"

module Vkit
  module CLI
    module Commands
      class PolicyPackAddCommand < BaseCommand
        def call(pack_name:, dir:, force: false)
          ensure_project!(dir)

          manager = Vkit::CLI::PolicyPack::Manager.new(
            project_root: dir
          )

          meta = manager.pack_metadata(pack_name)

          # Adding an installed pack again changes nothing, so it's not an
          # error (an agent may rerun a setup step).
          if manager.installed?(pack_name)
            version = manager.installed_packs.dig(pack_name, "version")
            puts "✓ #{pack_name} is already installed (v#{version})"
            return respond({ "pack" => pack_name, "version" => version, "already_existed" => true,
                             "policies_added" => 0 }, ["vkit policy bundle --format json"])
          end

          count = manager.install!(pack_name, force: force)

          puts "✅ Installed #{pack_name}"
          puts "   Version:  v#{meta['version']}"
          puts "   Policies: #{count} added"
          puts "\nRun 'vkit policy bundle' to compile."
          respond({ "pack" => pack_name, "version" => meta["version"], "already_existed" => false,
                    "policies_added" => count },
                  ["git add -A && git commit -m \"Add #{pack_name} policy pack\"", "vkit policy bundle --format json"])
        rescue StandardError => e
          raise if json?

          puts "❌ Error: #{e.message}"
          exit 1
        end

        private

        def ensure_project!(dir)
          dir = File.expand_path(dir)
          raise "Directory does not exist: #{dir}" unless Dir.exist?(dir)
          raise "Not a VaultKit project (missing .vkit/)" unless Dir.exist?(File.join(dir, ".vkit"))
        end
      end
    end
  end
end

# frozen_string_literal: true

require_relative "base_command"

module Vkit
  module CLI
    module Commands
      class PolicyPackRemoveCommand < BaseCommand
        def call(pack_name:, dir:, force: false)
          ensure_project!(dir)

          manager = Vkit::CLI::PolicyPack::Manager.new(
            project_root: dir
          )

          removed = manager.remove!(pack_name, force: force)

          puts "✅ Removed #{pack_name}"
          puts "   Files deleted: #{removed}"
          puts "\nRun 'vkit policy bundle' to recompile."
        rescue StandardError => e
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

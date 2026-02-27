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

          count = manager.install!(pack_name, force: force)
          meta  = manager.pack_metadata(pack_name)

          puts "✅ Installed #{pack_name}"
          puts "   Version:  v#{meta['version']}"
          puts "   Policies: #{count} added"
          puts "\nRun 'vkit policy bundle' to compile."
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

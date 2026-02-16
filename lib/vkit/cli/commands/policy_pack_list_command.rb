# frozen_string_literal: true

require_relative "base_command"

module Vkit
  module CLI
    module Commands
      class PolicyPackListCommand < BaseCommand
        def call(dir:)
          manager = Vkit::CLI::PolicyPack::Manager.new(
            project_root: dir
          )

          packs = manager.list_status

          if packs.empty?
            puts "No policy packs available."
            return
          end

          puts "Available policy packs:\n\n"

          packs.each do |p|
            name = p["name"]
            shipped = p["shipped_version"]
            installed = p["installed"]
            installed_version = p["installed_version"]
            drift = p["drift"]

            if installed
              if drift
                puts "⚠ #{name} (installed v#{installed_version}, available v#{shipped})"
              else
                puts "✓ #{name} v#{installed_version}"
              end
            else
              puts "  #{name} (not installed)"
            end
          end
        rescue StandardError => e
          puts "❌ Error: #{e.message}"
          exit 1
        end
      end
    end
  end
end

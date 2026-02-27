# frozen_string_literal: true

require_relative "base_command"

module Vkit
  module CLI
    module Commands
      class PolicyPackUpgradeCommand < BaseCommand
        def call(pack_name:, dir:, force: false)
          ensure_project!(dir)

          manager = Vkit::CLI::PolicyPack::Manager.new(
            project_root: dir
          )

          results =
            if pack_name
              [upgrade_single(manager, pack_name, force)]
            else
              manager.upgrade_all!(force: force)
            end

          print_summary(results)

          puts "\nRun 'vkit policy bundle' to recompile."
        rescue StandardError => e
          puts "❌ Error: #{e.message}"
          exit 1
        end

        private

        def upgrade_single(manager, pack, force)
          result = manager.upgrade!(pack, force: force)

          if result == :up_to_date
            { name: pack, status: :up_to_date }
          else
            {
              name: pack,
              status: :upgraded,
              old: result[:old_version],
              new: result[:new_version],
              policies: result[:policies]
            }
          end
        rescue => e
          { name: pack, status: :failed, error: e.message }
        end

        def print_summary(results)
          return if results.empty?

          puts "\nPolicy Pack Upgrade Summary\n"

          results.each do |r|
            case r[:status]
            when :up_to_date
              puts "✓ #{r[:name]} is already up to date"

            when :upgraded
              puts "✅ #{r[:name]}"
              puts "   From: v#{r[:old]}"
              puts "   To:   v#{r[:new]}"
              puts "   Policies updated: #{r[:policies]}"

            when :failed
              puts "❌ #{r[:name]}: #{r[:error]}"
            end
          end
        end

        def ensure_project!(dir)
          dir = File.expand_path(dir)
          raise "Directory does not exist: #{dir}" unless Dir.exist?(dir)
          raise "Not a VaultKit project (missing .vkit/)" unless Dir.exist?(File.join(dir, ".vkit"))
        end
      end
    end
  end
end

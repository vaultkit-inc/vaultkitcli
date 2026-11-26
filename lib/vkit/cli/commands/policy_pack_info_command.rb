# frozen_string_literal: true

require_relative "base_command"

module Vkit
  module CLI
    module Commands
      class PolicyPackInfoCommand < BaseCommand
        def call(pack_name:, dir:)
          manager = Vkit::CLI::PolicyPack::Manager.new(
            project_root: dir
          )

          meta = manager.pack_metadata(pack_name)

          puts "\nPolicy Pack: #{meta['name']}"
          puts "Version:     v#{meta['version']}"
          puts "Layer:       #{meta['layer'] || 'n/a'}"

          deps = Array(meta["dependencies"])
          puts "Dependencies: #{deps.empty? ? 'none' : deps.join(', ')}"

          band = meta["priority_band"]
          if band
            puts "Priority Band: #{band['min']} – #{band['max']}"
          end

          puts "\nPolicies Included:"
          policies = manager.send(:read_pack!, pack_name).last
          policies.each do |p|
            puts "  - #{p['id']}"
          end

          entry = manager.installed_packs[pack_name]
          if entry
            puts "\nInstalled: yes (v#{entry['version']})"
          else
            puts "\nInstalled: no"
          end

          respond({ "name" => meta["name"], "version" => meta["version"], "layer" => meta["layer"],
                    "dependencies" => deps, "priority_band" => band, "policies" => policies.map { |p| p["id"] },
                    "installed" => !entry.nil?, "installed_version" => entry && entry["version"] },
                  entry ? [] : ["vkit policy pack add #{pack_name} --format json"])
        rescue StandardError => e
          raise if json?

          puts "❌ Error: #{e.message}"
          exit 1
        end
      end
    end
  end
end

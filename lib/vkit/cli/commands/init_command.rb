# frozen_string_literal: true

require "fileutils"
require_relative "base_command"
require_relative "../policy_pack/manager"

module Vkit
  module CLI
    module Commands
      class InitCommand < BaseCommand
        def call(dir:, packs:)
          dir = File.expand_path(dir)
          FileUtils.mkdir_p(dir)

          create_structure(dir)

          manager = Vkit::CLI::PolicyPack::Manager.new(
            project_root: dir
          )

          total_policies = 0
          installed = []

          # Default secure behavior
          if packs.nil? || packs.empty?
            puts "\nℹ️  No packs specified. Installing 'starter' for secure defaults."
            packs = ["starter"]
          end

          packs.each do |pack_name|
            count = manager.install_with_deps!(pack_name)
            total_policies += count
            installed << pack_name

            metadata = manager.pack_metadata(pack_name)
            puts "✓ Installed #{pack_name} pack (v#{metadata['version']}) - #{count} policies"
          end

          puts "\n✅ VaultKit project initialized"
          puts "   Location: #{dir}"
          puts "   Packs:    #{installed.join(', ')}"
          puts "   Policies: #{total_policies} total"

          puts "\nNext steps:"
          puts "  1. Review policies in config/policies/"
          puts "  2. Run: vkit scan <datasource> --apply"
          puts "  3. Run: vkit policy bundle"
          puts "  4. Run: vkit policy deploy"

        rescue StandardError => e
          puts "❌ Error: #{e.message}"
          exit 1
        end

        private

        def create_structure(dir)
          FileUtils.mkdir_p(File.join(dir, "config", "policies"))
          FileUtils.mkdir_p(File.join(dir, "datasets"))
          FileUtils.mkdir_p(File.join(dir, "dist"))
          FileUtils.mkdir_p(File.join(dir, ".vkit"))

          registry_path = File.join(dir, "datasets", "registry.yaml")
          unless File.exist?(registry_path)
            File.write(
              registry_path,
              "# Dataset registry\n# Populate with: vkit scan <datasource> --apply\n"
            )
          end

          gitignore_path = File.join(dir, ".gitignore")
          unless File.exist?(gitignore_path)
            File.write(
              gitignore_path,
              "dist/\n.vkit/\n"
            )
          end
        end
      end
    end
  end
end

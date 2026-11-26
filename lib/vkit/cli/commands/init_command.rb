# frozen_string_literal: true

require "fileutils"
require_relative "base_command"
require_relative "../policy_pack/manager"
require_relative "../../policy/git_state"
require_relative "../../policy/pack_integrity"

module Vkit
  module CLI
    module Commands
      class InitCommand < BaseCommand
        # .vkit/packs.yaml records the installed packs, and vkit policy bundle
        # checks them against it, so it's committed. Nothing else in .vkit/ is
        # (nothing else is written there today).
        GITIGNORE = <<~IGNORE
          dist/
          .vkit/*
          !.vkit/packs.yaml
        IGNORE

        def call(dir:, packs:, git: true)
          dir = File.expand_path(dir)
          already = initialized?(dir)
          FileUtils.mkdir_p(dir)

          git_initialized = git ? init_git(dir) : false
          create_structure(dir)

          manager = Vkit::CLI::PolicyPack::Manager.new(
            project_root: dir
          )

          total_policies = 0
          installed = []

          # Default secure behavior
          # (only for a new project: rerunning init leaves the packs as they are)
          if (packs.nil? || packs.empty?) && already
            packs = []
          elsif packs.nil? || packs.empty?
            puts "\nℹ️  No packs specified. Installing 'starter' for secure defaults."
            packs = ["starter"]
          end

          pack_results = []
          packs.each do |pack_name|
            was_installed = manager.installed?(pack_name)
            count = manager.install_with_deps!(pack_name)
            total_policies += count
            installed << pack_name

            metadata = manager.pack_metadata(pack_name)
            pack_results << { "name" => pack_name, "version" => metadata["version"], "policies_added" => count,
                              "already_installed" => was_installed }
            puts "✓ Installed #{pack_name} pack (v#{metadata['version']}) - #{count} policies"
          end

          puts "\n✅ VaultKit project initialized"
          puts "   Location: #{dir}"
          puts "   Packs:    #{installed.join(', ')}"
          puts "   Policies: #{total_policies} total"

          puts "\nNext steps:"
          puts "  1. Review policies in config/policies/"
          puts "  2. Run: vkit scan <datasource> --mode apply"
          puts "  3. Commit: git add -A && git commit -m \"Add VaultKit policies\""
          puts "  4. Run: vkit policy bundle"
          puts "  5. Run: vkit policy deploy"

          respond(
            { "dir" => dir, "already_existed" => already, "git_initialized" => git_initialized,
              "packs" => pack_results, "policies_added" => total_policies },
            init_next_steps(dir)
          )
        rescue StandardError => e
          raise if json?

          puts "❌ Error: #{e.message}"
          exit 1
        end

        private

        # Initialised before: it has the pack record init writes.
        def initialized?(dir)
          File.exist?(File.join(dir, Vkit::Policy::PackIntegrity::TRACKING_PATH))
        end

        def init_next_steps(dir)
          cd = File.expand_path(dir) == Dir.pwd ? [] : ["cd #{dir}"]
          cd + [
            "vkit datasource add --id <id> --engine <engine> --username <user> --config '<json>' " \
            "--region <region> --environment <env> --password-prompt",
            "vkit scan <datasource> --mode apply --format json",
            "vkit registry export --force --format json"
          ]
        end

        # A bundle's version is the commit its policies are in, so a new
        # project starts as a repository. Never commits.
        def init_git(dir)
          return false if Vkit::Policy::GitState.new(dir).repo?

          if system("git", "init", "--quiet", dir, out: File::NULL, err: File::NULL)
            puts "✓ Initialized a git repository in #{dir}"
            true
          else
            puts "⚠️  Couldn't run git init (is git installed?). vkit policy bundle needs a git repository " \
                 "or --version."
            false
          end
        end

        def create_structure(dir)
          FileUtils.mkdir_p(File.join(dir, "config", "policies"))
          FileUtils.mkdir_p(File.join(dir, "datasets"))
          FileUtils.mkdir_p(File.join(dir, "dist"))
          FileUtils.mkdir_p(File.join(dir, ".vkit"))
        
          registry_path = File.join(dir, "datasets", "registry.yaml")
        
          if File.exist?(registry_path)
            puts "ℹ️  datasets/registry.yaml already exists — leaving unchanged."
          else
            File.write(
              registry_path,
              <<~YAML
                # VaultKit Dataset Registry
                #
                # Populate with:
                #   vkit scan <datasource> --mode apply
                #   vkit registry export
                #
              YAML
            )
          end
        
          gitignore_path = File.join(dir, ".gitignore")
          File.write(gitignore_path, GITIGNORE) unless File.exist?(gitignore_path)
        end        
      end
    end
  end
end

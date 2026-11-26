# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "../../policy/bundle_compiler"
require_relative "../../policy/validation_error"
require_relative "../../policy/git_state"
require_relative "../../policy/pack_integrity"
require_relative "../errors"

module Vkit
  module CLI
    module Commands
      class PolicyBundleCommand < BaseCommand
        def call(policies_dir:, registry_dir:, out:, org:, version:, allow_dirty: false)
          inputs = [policies_dir, registry_dir, Vkit::Policy::PackIntegrity::TRACKING_PATH]
          policies_dir = File.expand_path(policies_dir)
          registry_dir = File.expand_path(registry_dir)
          out          = File.expand_path(out)

          missing_dir!("Policies", policies_dir, "--policies-dir") unless Dir.exist?(policies_dir)
          missing_dir!("Registry", registry_dir, "--registry-dir") unless Dir.exist?(registry_dir)

          git = Vkit::Policy::GitState.new(Dir.pwd)
          source = source_for(git, version, inputs, allow_dirty)
          version ||= source[:commit_sha]

          with_auth do
            derived_org = credential_store.user["organization_slug"]

            raise "Unable to determine organization from credentials. Please login." \
              if derived_org.nil? || derived_org.empty?

            if org && org != derived_org
              raise <<~MSG
                Organization mismatch detected.

                  Authenticated organization: #{derived_org}
                  Provided via --org:          #{org}

                Refusing to continue to prevent cross-organization policy bundles.
              MSG
            end

            org_slug = org || derived_org

            bundle = Vkit::Policy::BundleCompiler.compile!(
              org_slug: org_slug,
              bundle_version: version,
              policies_dir: policies_dir,
              registry_dir: registry_dir,
              source: source,
              created_at: created_at(git, source, inputs)
            )

            FileUtils.mkdir_p(File.dirname(out))
            File.write(out, JSON.pretty_generate(bundle))

            puts "✅ Policy bundle created"
            puts "   Org:      #{bundle.dig("bundle", "org_slug")}"
            puts "   Version:  #{bundle.dig("bundle", "bundle_version")}"
            puts "   Checksum: #{bundle.dig("bundle", "checksum")}"
            puts "   Output:   #{out}"
            print_policy_summary(bundle, policies_dir)

            respond(
              { "org" => bundle.dig("bundle", "org_slug"), "bundle_version" => bundle.dig("bundle", "bundle_version"),
                "checksum" => bundle.dig("bundle", "checksum"), "output" => out, "dirty" => source[:dirty] == true,
                "policies" => bundle["policies"].length,
                "packs" => Array(bundle.dig("bundle", "installed_packs")).map do |p|
                  { "name" => p["name"], "version" => p["version"], "policies" => Array(p["policy_ids"]).length }
                end },
              ["vkit policy deploy --bundle #{relative(out)} --format json"]
            )
          end
        rescue Vkit::CLI::CommandError => e
          raise if json?

          puts e.render
          exit 1
        rescue Vkit::Policy::ValidationError => e
          raise if json?

          puts e.message
          exit 1
        end

        private

        # Message as before; the code is for --format json.
        def missing_dir!(what, dir, flag)
          raise "#{what} dir not found: #{dir}" unless json?

          raise Vkit::CLI::CommandError.new(
            "#{what} dir not found: #{dir}", code: "not_a_project",
            fix: ["Run this from a VaultKit project (`vkit init`), or pass #{flag} <dir>."]
          )
        end

        # The bundle's source block. commit_sha is the commit the policies are
        # in, from git only; --version only names the bundle. Refuses to bundle
        # what can't be traced to a commit, unless told to.
        def source_for(git, version, inputs, allow_dirty)
          unless git.repo?
            raise not_versioned unless version

            return {}
          end

          head = git.head
          raise not_versioned unless head || version

          source = { repo: git.remote_url, ref: git.branch, commit_sha: head }
          changed = git.uncommitted(inputs)
          return source if changed.empty?
          raise not_committed(changed, inputs) unless allow_dirty

          warn_dirty(changed)
          source.merge(dirty: true)
        end

        # The bundle's created_at, from what it's built from rather than the
        # clock, so bundling the same commit again gives the same checksum and
        # redeploying it answers already_deployed (a version is uploaded only
        # once, with one checksum). A clean commit uses its commit time.
        # Uncommitted inputs (--allow-dirty) or no repo (--version) use the
        # newest input file's modification time, at least the commit's.
        def created_at(git, source, inputs)
          committed = git.commit_time(source[:commit_sha]) if source[:commit_sha]
          return committed if committed && !source[:dirty]

          [committed, newest_mtime(inputs)].compact.max || Time.now
        end

        def newest_mtime(inputs)
          inputs.flat_map { |path| File.directory?(path) ? Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH) : [path] }
                .select { |path| File.file?(path) }
                .map { |path| File.mtime(path) }
                .max
        end

        def not_versioned
          Vkit::CLI::CommandError.new(
            "This policy project isn't in a git repository, so the bundle would have no version.",
            code: "bundle_not_versioned",
            fix: ["git init && git add -A && git commit -m \"Add VaultKit policies\"",
                  "or name the bundle: vkit policy bundle --version <label>"]
          )
        end

        def not_committed(changed, inputs)
          ignored = changed.select { |c| c[:ignored] }.map { |c| c[:path] }
          fix = ["git add -A -- #{inputs.join(' ')}"]
          fix << "git add -f -- #{ignored.join(' ')}" if ignored.any?
          if ignored.include?(Vkit::Policy::PackIntegrity::TRACKING_PATH)
            fix << "and in .gitignore, replace .vkit/ with two lines: .vkit/* and !.vkit/packs.yaml"
          end
          # Only the commit: agents following setup.md never bundle dirty, so
          # --allow-dirty is left to `vkit help policy bundle`.
          fix << "git commit -m \"Update VaultKit policies\""
          files = changed.map { |c| "   #{c[:path]}#{' (ignored by .gitignore)' if c[:ignored]}" }

          Vkit::CLI::CommandError.new(
            "These files aren't committed, so the bundle's version wouldn't match its policies:\n#{files.join("\n")}",
            code: "bundle_not_committed",
            fix: fix
          )
        end

        def warn_dirty(changed)
          puts "⚠️  Bundling uncommitted changes (--allow-dirty). The bundle is recorded as dirty:"
          changed.each { |c| puts "   #{c[:path]}" }
        end

        # Per-pack counts on every bundle, so a pack that contributes nothing
        # is visible even when nothing errors.
        def print_policy_summary(bundle, policies_dir)
          total = bundle["policies"].length
          packs = Array(bundle.dig("bundle", "installed_packs"))
          from_packs = packs.sum { |p| Array(p["policy_ids"]).length }
          rows = packs.map { |p| ["#{p["name"]} #{p["version"]}", Array(p["policy_ids"]).length] }
          rows << ["repo (#{relative(policies_dir)})", total - from_packs]
          width = rows.map { |label, _| label.length }.max

          puts "   Policies: #{total}"
          rows.each { |label, count| puts "     #{label.ljust(width)}  #{count}" }
        end

        def relative(path)
          path.delete_prefix(Dir.pwd + File::SEPARATOR)
        end
      end
    end
  end
end

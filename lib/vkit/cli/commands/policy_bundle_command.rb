require "json"
require_relative "../../policy/bundle_compiler"

module Vkit
  module CLI
    module Commands
      class PolicyBundleCommand
        def call(policies_dir:, registry_dir:, out:, org:, version:)
          policies_dir = File.expand_path(policies_dir)
          registry_dir = File.expand_path(registry_dir)
          out          = File.expand_path(out)

          raise "Policies dir not found: #{policies_dir}" unless Dir.exist?(policies_dir)
          raise "Registry dir not found: #{registry_dir}" unless Dir.exist?(registry_dir)

          version ||= git_sha

          bundle = Vkit::Policy::BundleCompiler.compile!(
            org_slug: org || "unknown",
            bundle_version: version,
            policies_dir: policies_dir,
            registry_dir: registry_dir,
            source: {
              repo: git_repo,
              ref: git_ref,
              commit_sha: version
            }
          )

          FileUtils.mkdir_p(File.dirname(out))
          File.write(out, JSON.pretty_generate(bundle))

          puts "✅ Policy bundle created"
          puts "   Org:     #{bundle.dig("bundle", "org_slug")}"
          puts "   Version: #{bundle.dig("bundle", "bundle_version")}"
          puts "   Checksum: #{bundle.dig("bundle", "checksum")}"
          puts "   Output:  #{out}"
        end

        private

        def git_sha
          `git rev-parse HEAD`.strip
        rescue
          Time.now.to_i.to_s
        end

        def git_repo
          `git config --get remote.origin.url`.strip
        rescue
          nil
        end

        def git_ref
          `git rev-parse --abbrev-ref HEAD`.strip
        rescue
          nil
        end
      end
    end
  end
end

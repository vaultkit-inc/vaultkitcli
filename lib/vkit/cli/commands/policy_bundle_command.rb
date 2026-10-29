# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "../../policy/bundle_compiler"
require_relative "../../policy/validation_error"

module Vkit
  module CLI
    module Commands
      class PolicyBundleCommand < BaseCommand
        def call(policies_dir:, registry_dir:, out:, org:, version:)
          policies_dir = File.expand_path(policies_dir)
          registry_dir = File.expand_path(registry_dir)
          out          = File.expand_path(out)

          raise "Policies dir not found: #{policies_dir}" unless Dir.exist?(policies_dir)
          raise "Registry dir not found: #{registry_dir}" unless Dir.exist?(registry_dir)

          version ||= git_sha

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
              source: {
                repo: git_repo,
                ref: git_ref,
                commit_sha: version
              }
            )

            FileUtils.mkdir_p(File.dirname(out))
            File.write(out, JSON.pretty_generate(bundle))

            puts "✅ Policy bundle created"
            puts "   Org:      #{bundle.dig("bundle", "org_slug")}"
            puts "   Version:  #{bundle.dig("bundle", "bundle_version")}"
            puts "   Checksum: #{bundle.dig("bundle", "checksum")}"
            puts "   Output:   #{out}"
          end
        rescue Vkit::Policy::ValidationError => e
          puts e.message
          exit 1
        end

        private

        def git_sha
          out = `git rev-parse HEAD 2>/dev/null`.strip
          return nil if out.empty?
        
          out
        end
        
        def git_repo
          out = `git config --get remote.origin.url 2>/dev/null`.strip
          out.empty? ? nil : out
        end
        
        def git_ref
          out = `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
          out.empty? ? nil : out
        end        
      end
    end
  end
end

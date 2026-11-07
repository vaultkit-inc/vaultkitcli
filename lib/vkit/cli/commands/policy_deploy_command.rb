# frozen_string_literal: true

require "json"
require "digest"
require_relative "../../policy/pack_integrity"
require_relative "../../policy/bundle_compiler"

module Vkit
  module CLI
    module Commands
      class PolicyDeployCommand < BaseCommand
        def call(bundle_path:, org:, activate:)
          with_auth do
            bundle_path = File.expand_path(bundle_path)
            raise "Bundle not found: #{bundle_path}" unless File.exist?(bundle_path)

            derived_org = credential_store.user["organization_slug"]

            raise "Unable to determine organization from credentials. Please login." \
              if derived_org.nil? || derived_org.empty?

            if org && org != derived_org
              raise <<~MSG
                Organization mismatch detected.

                  Authenticated organization: #{derived_org}
                  Provided via --org:          #{org}

                Refusing to deploy policy bundle to a different organization.
              MSG
            end

            org_slug = org || derived_org

            bundle = JSON.parse(File.read(bundle_path))
            Vkit::Policy::PackIntegrity.check_bundle!(bundle)

            response = upload(org_slug, bundle, activate)

            puts "🚀 Policy bundle deployed"
            puts "   Org:     #{org_slug}"
            puts "   Version: #{response['bundle_version']}"
            puts "   State:   #{response['state']}"
          end
        rescue Vkit::Policy::ValidationError => e
          puts e.message
          exit 1
        end

        private

        # A control plane from before vaultkitcli#47 doesn't know installed_packs'
        # policy_ids and rejects the bundle on schema. The ids were checked
        # above, so send the bundle without them (re-checksummed) instead.
        def upload(org_slug, bundle, activate)
          post_bundle(org_slug, bundle, activate)
        rescue Vkit::CLI::API::APIError => e
          raise unless e.status == 422 && e.error.to_s.match?(%r{installed_packs/\d+/policy_ids})

          warn "ℹ️  This control plane predates per-pack policy checks; deploying without them."
          post_bundle(org_slug, without_policy_ids(bundle), activate)
        end

        def post_bundle(org_slug, bundle, activate)
          authenticated_client.post(
            "/api/v1/orgs/#{org_slug}/policy_bundles",
            body: {
              bundle: bundle,
              activate: activate
            }
          )
        end

        def without_policy_ids(bundle)
          copy = JSON.parse(JSON.generate(bundle))
          Array(copy.dig("bundle", "installed_packs")).each { |p| p.delete("policy_ids") }
          copy["bundle"]["checksum"] = ""
          copy["bundle"]["checksum"] = Digest::SHA256.hexdigest(Vkit::Policy::BundleCompiler.canonical_json(copy))
          copy
        end
      end
    end
  end
end

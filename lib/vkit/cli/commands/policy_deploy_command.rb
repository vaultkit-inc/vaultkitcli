# frozen_string_literal: true

require "json"
require "digest"
require_relative "../../policy/pack_integrity"
require_relative "../../policy/bundle_compiler"
require_relative "../../policy/approval_groups"

module Vkit
  module CLI
    module Commands
      class PolicyDeployCommand < BaseCommand
        def call(bundle_path:, org:, activate:, format: "human")
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
            warnings = deploy_warnings(org_slug, bundle, response)

            if format == "json"
              puts JSON.pretty_generate(
                "status" => "deployed", "org" => org_slug, "bundle_version" => response["bundle_version"],
                "state" => response["state"], "checksum" => response["checksum"], "warnings" => warnings
              )
            else
              print_deployed(org_slug, response, warnings)
            end
          end
        rescue Vkit::Policy::ValidationError => e
          puts e.message
          exit 1
        end

        private

        def print_deployed(org_slug, response, warnings)
          puts "🚀 Policy bundle deployed"
          puts "   Org:     #{org_slug}"
          puts "   Version: #{response['bundle_version']}"
          puts "   State:   #{response['state']}"
          return if warnings.empty?

          puts
          warnings.each { |w| puts "⚠️  #{w['message']}" }
        end

        # The control plane returns one warning per approval group nobody is
        # in. Older control planes don't, so the same rule is applied here to
        # the groups they list. A failure to list them never fails the deploy.
        def deploy_warnings(org_slug, bundle, response)
          return Array(response["warnings"]) if response.is_a?(Hash) && response.key?("warnings")

          listed = authenticated_client.get("/api/v1/orgs/#{org_slug}/approval_groups")
          Vkit::Policy::ApprovalGroups.warnings(bundle, listed.is_a?(Hash) ? listed["groups"] : [])
        rescue StandardError
          []
        end

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

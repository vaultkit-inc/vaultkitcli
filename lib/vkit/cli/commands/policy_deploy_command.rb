# frozen_string_literal: true

require "json"

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

            response = authenticated_client.post(
              "/api/v1/orgs/#{org_slug}/policy_bundles",
              body: {
                bundle: bundle,
                activate: activate
              }
            )

            puts "🚀 Policy bundle deployed"
            puts "   Org:     #{org_slug}"
            puts "   Version: #{response['bundle_version']}"
            puts "   State:   #{response['state']}"
          end
        end
      end
    end
  end
end

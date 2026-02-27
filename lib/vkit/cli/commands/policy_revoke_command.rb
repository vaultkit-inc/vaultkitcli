# frozen_string_literal: true

module Vkit
  module CLI
    module Commands
      class PolicyRevokeCommand < BaseCommand
        def call(bundle_version:, reason:, force:)
          with_auth do
            user = credential_store.user
            org  = user["organization_slug"]

            raise "Not authenticated. Please login." if org.nil? || org.empty?

            unless force
              puts "⚠️  You are about to revoke policy bundle version: #{bundle_version}"
              puts "   Organization: #{org}"
              puts "   Reason: #{reason || 'Bundle revoked via CLI'}"
              print "Continue? (y/N): "
              answer = STDIN.gets.strip
              return puts("Aborted.") unless answer.downcase == "y"
            end

            response =
              authenticated_client.post(
                "/api/v1/orgs/#{org}/policy_bundles/#{bundle_version}/revoke",
                body: {
                  reason: reason
                }
              )

            puts "✅ Policy bundle revoked"
            puts "   Version:  #{response["bundle_version"]}"
            puts "   Checksum: #{response["checksum"]}"
            puts "   Revoked:  #{response["revoked_at"]}"
          end
        end
      end
    end
  end
end

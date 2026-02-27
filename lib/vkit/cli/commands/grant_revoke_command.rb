# frozen_string_literal: true

module Vkit
  module CLI
    module Commands
      class GrantRevokeCommand < BaseCommand
        def call(grant_ref:, reason:, force:)
          with_auth do
            user = credential_store.user
            org  = user["organization_slug"]

            raise "Not authenticated. Please login." if org.nil? || org.empty?

            unless force
              puts "⚠️  You are about to revoke grant: #{grant_ref}"
              puts "   Organization: #{org}"
              puts "   Reason: #{reason || 'Grant revoked via CLI'}"
              print "Continue? (y/N): "
              answer = STDIN.gets.strip
              return puts("Aborted.") unless answer.downcase == "y"
            end

            response =
              authenticated_client.post(
                "/api/v1/orgs/#{org}/grants/#{grant_ref}/revoke",
                body: {
                  reason: reason
                }
              )

            puts "✅ Grant revoked"
            puts "   Grant:   #{grant_ref}"
            puts "   Revoked: #{response["revoked_at"]}"
          end
        end
      end
    end
  end
end

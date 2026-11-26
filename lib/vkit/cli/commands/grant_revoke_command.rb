# frozen_string_literal: true

module Vkit
  module CLI
    module Commands
      class GrantRevokeCommand < BaseCommand
        def call(grant_ref:, reason:, force:)
          reason = reason.to_s.strip
          # The control plane refuses a revoke without one.
          raise "A reason is required (--reason)" if reason.empty?

          with_auth do
            user = credential_store.user
            org  = user["organization_slug"]

            raise "Not authenticated. Please login." if org.nil? || org.empty?

            unless force
              confirmation_needed!("Revoking grant #{grant_ref}", "--yes") if json?

              puts "⚠️  You are about to revoke grant: #{grant_ref}"
              puts "   Organization: #{org}"
              puts "   Reason: #{reason}"
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
            respond({ "grant" => grant_ref, "revoked_at" => response["revoked_at"] })
          end
        end
      end
    end
  end
end

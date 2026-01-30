# frozen_string_literal: true

require "json"

module Vkit
  module CLI
    module Commands
      class ApprovalCommand < BaseCommand
        DEFAULT_TTL = 3600

        def call_list(state: "pending")
          with_auth do
            user = credential_store.user
            org  = user["organization_slug"]

            rows = authenticated_client.get(
              "/api/v1/orgs/#{org}/approvals?state=#{state}"
            )

            if rows.empty?
              puts empty_message_for(state)
              return
            end

            puts "📋 Approvals (#{rows.size}, state=#{state})"
            rows.each do |r|
              puts "─" * 60
              puts "🆔  #{r["id"]}"
              puts "📂  Dataset:    #{r["dataset"]}"
              puts "📄  Fields:     #{Array(r["fields"]).join(', ')}"
              puts "👤  Requester:  #{r["requester_email"]}"
              puts "🔐  Required:   #{r["approver_role"] || 'n/a'}"
              puts "⚙️   Status:     #{r["state"].capitalize}"
              puts "🔑  Grant Ref:  #{r["grant_ref"] || 'n/a'}" if r["state"] == "approved"
              puts "💬  Reason:     #{r["reason"]}"
              puts "📅  Created:    #{r["created_at"]}"
            end
            puts "─" * 60
          end
        end

        def call_approve(id:, ttl_seconds: DEFAULT_TTL)
          with_auth do
            user = credential_store.user
            org  = user["organization_slug"]

            res = authenticated_client.post(
              "/api/v1/orgs/#{org}/approvals/#{id}/approve",
              body: { ttl_seconds: ttl_seconds }
            )

            puts "✅ Approved request #{id}"
            puts "   → Grant Ref: #{res["grant_ref"] || res["grant_id"]}"
            puts "   → Expires:   #{res["expires_at"]}"
          end
        end

        def call_deny(id:, reason: nil)
          with_auth do
            user = credential_store.user
            org  = user["organization_slug"]

            reason ||= prompt_reason
            raise "Denial reason cannot be empty" if reason.to_s.empty?

            authenticated_client.post(
              "/api/v1/orgs/#{org}/approvals/#{id}/deny",
              body: { reason: reason }
            )

            puts "🚫 Denied request #{id}"
            puts "   → Reason: #{reason}"
          end
        end

        private

        def prompt_reason
          print "Enter reason for denial: "
          STDIN.gets&.strip
        end

        def empty_message_for(state)
          case state
          when "pending"  then "📭 No pending approvals."
          when "approved" then "📭 No approved requests."
          when "denied"   then "📭 No denied requests."
          else                 "📭 No approvals found."
          end
        end
      end
    end
  end
end

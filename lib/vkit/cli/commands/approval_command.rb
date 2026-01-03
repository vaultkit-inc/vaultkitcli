# frozen_string_literal: true

require "json"
require_relative "../api/client"
require_relative "../../core/credential_store"

module Vkit
  module CLI
    module Commands
      class ApprovalCommand
        DEFAULT_TTL = 3600

        def initialize(api_url: ENV["VKIT_API_URL"])
          raise "VKIT_API_URL not set" unless api_url
          @api_url = api_url.chomp("/")
        end

        # LIST
        def call_list(state: "pending")
          user = current_user
          org  = user["organization_slug"]

          rows = client.get(
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
        rescue Vkit::CLI::API::APIError => e
          puts "❌ Failed to list approvals"
          puts e.message
          exit 1
        end

        # APPROVE
        def call_approve(id:, ttl_seconds: DEFAULT_TTL)
          user = current_user
          org  = user["organization_slug"]

          res = client.post(
            "/api/v1/orgs/#{org}/approvals/#{id}/approve",
            body: { ttl_seconds: ttl_seconds }
          )

          puts "✅ Approved request #{id}"
          puts "   → Grant Ref: #{res["grant_ref"] || res["grant_id"]}"
          puts "   → Expires:   #{res["expires_at"]}"

        rescue Vkit::CLI::API::APIError => e
          puts "❌ Approval failed"
          puts e.message
          exit 1
        end

        # DENY
        def call_deny(id:, reason: nil)
          user = current_user
          org  = user["organization_slug"]

          reason ||= prompt_reason
          raise "Denial reason cannot be empty" if reason.to_s.empty?

          client.post(
            "/api/v1/orgs/#{org}/approvals/#{id}/deny",
            body: { reason: reason }
          )

          puts "🚫 Denied request #{id}"
          puts "   → Reason: #{reason}"

        rescue Vkit::CLI::API::APIError => e
          puts "❌ Deny failed"
          puts e.message
          exit 1
        end

        private

        def client
          @client ||= Vkit::CLI::API::Client.new(
            base_url: @api_url,
            token: require_token!
          )
        end

        def current_user
          creds = Vkit::Core::CredentialStore.new
          user  = creds.load_user
          raise "Not logged in. Run: vkit login" unless user
          user
        end

        def require_token!
          creds = Vkit::Core::CredentialStore.new
          token = creds.load_token
          raise "Missing auth token. Run: vkit login" unless token
          token
        end

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

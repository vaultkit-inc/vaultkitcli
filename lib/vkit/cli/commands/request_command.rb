require "json"
require_relative "../../core/request_orchestrator"
require_relative "../../core/table_formatter"
require_relative "../../core/grant_store"

module Vkit
  module CLI
    module Commands
      class RequestCommand
        def initialize(funl_url:)
          @funl_url = funl_url
          @grants = Vkit::Core::GrantStore.new
        end

        # options comes from Thor (env, requester_region, dataset_region, policies_dir, registry)
        # aql_str: passed inline via --aql or read from STDIN if nil
        def call(aql_str, options)
          aql_payload =
            if aql_str && !aql_str.strip.empty?
              aql_str
            else
              STDIN.read
            end

          raise "No AQL provided. Use --aql '{...}' or pipe JSON to STDIN." if aql_payload.nil? || aql_payload.strip.empty?

          orch = Vkit::Core::RequestOrchestrator.new(
            policies_dir:  options[:policies_dir] || "config/policies",
            registry_path: options[:registry]     || "datasets/registry.yaml",
            funl_url: @funl_url || (ENV["FUNL_URL"] || "http://localhost:8080")
          )

          result = orch.run_inline(
            aql_json: aql_payload,
            options: {
              environment:      options[:env],
              requester_region: options[:requester_region],
              dataset_region:   options[:dataset_region]
            }
          )

          handle_result(result, options)
        rescue => e
          warn "❌ Request failed: #{e.message}"
          exit 1
        end

        def call_list
          user = require_login!
          email = user["email"]

          rows = Vkit::Core::ApprovalStore.new.list_for_user(email)

          if rows.empty?
            puts "📭 No past requests for #{email}"
            return
          end

          puts "📋 Past Requests (#{rows.size})"
          rows.each do |r|
            puts "─" * 60
            puts "🆔  #{r[:id]}"
            puts "📂 Dataset:    #{r[:dataset]}"
            puts "📄 Fields:     #{r[:fields].join(', ')}"
            puts "🔐 State:      #{r[:state]}"
            puts "📅 Created:    #{r[:created_at]}"
            puts "✔ Approved At: #{r[:approved_at] || '-'}"
            if r[:state] == "approved"
              grant = @grants.list.find { |g| g[:id] == r[:grant_id] }
              if grant
                puts "🔑 Grant ID: #{grant[:id]}"
                puts "⏳ Expires: #{grant[:expires_at]}"
              end
            end
          end
          puts "─" * 60
        end

        def call_show(id)
          user = require_login!
          email = user["email"]

          store = Vkit::Core::ApprovalStore.new
          req = store.fetch_for_user(id, email)
          raise "Request not found or not owned by you" unless req

          puts "📄 Request Details"
          puts "─" * 60
          puts "🆔  ID:         #{req[:id]}"
          puts "📂 Dataset:    #{req[:dataset]}"
          puts "📄 Fields:     #{req[:fields].join(', ')}"
          puts "💬 Reason:     #{req[:reason]}"
          puts "🔐 State:      #{req[:state]}"
          puts "📅 Created:    #{req[:created_at]}"
          puts "✔ Approved At: #{req[:approved_at] || '-'}"
          if req[:state] == "approved"
            grant = @grants.list.find { |g| g[:id] == req[:grant_id] }
            if grant
              puts "🔑 Grant ID: #{grant[:id]}"
              puts "⏳ Expires: #{grant[:expires_at]}"
            end
          end
          puts "─" * 60
        end

        private

        def require_login!
          creds = Vkit::Core::CredentialStore.new
          user  = creds.load_user
          raise "Not logged in. Run: vkit login" if user.nil?
          user
        end

        def handle_result(result, options)
          case result[:status]
          when :denied
            puts "❌ DENIED (policy: #{result[:policy_id]})"
            puts "   reason: #{result[:reason]}"
            exit 2

          when :queued
            puts "⏳ QUEUED for approval"
            puts "   request_id: #{result[:request_id]}"
            puts "   approver_role: #{result[:approver_role]}"
            puts "   reason: #{result[:reason]}"
            exit 0

          when :granted
            puts "✅ ACCESS GRANTED"
            puts "   Grant ID: #{result[:grant_id]}"
            puts "   Session Token: #{result[:session_token]}"
            puts "   Expires At: #{result[:expires_at]}"
            puts "   Masked Fields: #{(result[:masked_fields] || []).join(', ')}"
            puts "\nTo retrieve data, run:"
            puts "   vkit fetch --grant #{result[:grant_id]}"
            exit 0

          when :ok
            rows = result[:rows] || []
            puts "✅ OK — rows: #{rows.size}"

            case options[:format]
            when "json"
              puts JSON.pretty_generate(rows)
            when "table"
              Vkit::Core::TableFormatter.render(rows)
            end

            exit 0

          else
            puts "Unexpected result: #{result.inspect}"
            exit 1
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require "json"
require "time"
require_relative "../../core/table_formatter"
require_relative "approval_roles"

module Vkit
  module CLI
    module Commands
      class RequestCommand < BaseCommand
        def call(aql_str, options)
          with_auth do
            user = credential_store.user
            org  = user["organization_slug"]

            aql =
              if aql_str&.strip&.length&.positive?
                JSON.parse(aql_str)
              elsif json? && $stdin.tty?
                raise Vkit::CLI::CommandError.new("No AQL given.", code: "aql_required",
                                                  fix: ["Pass the request with --aql '<json>' or pipe it on stdin."])
              else
                JSON.parse(STDIN.read)
              end

            response = authenticated_client.post(
              "/api/v1/orgs/#{org}/requests",
              body: {
                aql: aql,
                options: {
                  environment: options[:env],
                  requester_region: options[:requester_region],
                  dataset_region: options[:dataset_region],
                  requester_clearance: options[:requester_clearance],
                  datasource: options[:datasource]
                }.compact
              }
            )

            handle_result(response, options)
          end
        rescue JSON::ParserError
          raise "Invalid JSON AQL"
        end

        private

        # A denial is the request's answer, not a CLI failure, but it's what
        # the agent asked for not happening, so it's an error (exit 2, as
        # before). Queued and granted are ok, with what to run next.
        def respond_json(result)
          status = result["status"]
          if status == "denied"
            raise Vkit::CLI::CommandError.new(
              result["reason"].to_s.empty? ? "Request denied by policy" : result["reason"],
              code: "request_denied", exit_code: 2,
              fix: ["Policy denied this request; ask for fewer or less sensitive fields, or ask an admin " \
                    "about the policy (request_id #{result["request_id"]})."]
            )
          end

          next_steps =
            case status
            when "granted" then ["vkit fetch --grant #{result["grant_ref"]} --format json"]
            when "pending_approval", "queued" then ["vkit requests list --state pending --format json"]
            else []
            end
          respond(result, next_steps)
        end

        # Every response names its request; the console's Activity page
        # finds it by this id.
        def print_request_id(result)
          return if result["request_id"].to_s.empty?

          puts "Request ID: #{result["request_id"]} (look it up under Activity in the console)"
        end

        def print_queued(result)
          puts "⏳ QUEUED for approval"
          print_request_id(result)

          roles = ApprovalRoles.required_roles(result)
          puts "Approver roles: #{roles.join(', ')}" if roles.any?
          puts "Reason: #{result["reason"]}" if result["reason"].to_s.strip != ""

          puts
          puts "Once it's approved, run the same request again to get the data."
        end

        def handle_result(result, options)
          status = result["status"]

          return respond_json(result) if options[:format] == "json"

          case status
          when "denied"
            puts "❌ DENIED"
            puts "Reason: #{result["reason"]}"
            print_request_id(result)
            exit 2

          # The control plane answers "pending_approval"; "queued" is what
          # older control planes sent.
          when "pending_approval", "queued"
            print_queued(result)
            exit 0

          when "granted"
            expires_at = Time.parse(result["expires_at"]).getlocal

            puts "✅ ACCESS GRANTED"
            puts "Grant Ref: #{result["grant_ref"]}"
            print_request_id(result)
            puts "Expires: #{expires_at.strftime("%Y-%m-%d %H:%M:%S %Z")}"

            if (mask = result["masked_fields"]) && mask.any?
              puts "Masked Fields: #{mask.join(', ')}"
            else
              puts "Masked Fields: none"
            end

            puts
            puts "To execute and retrieve the data, run:"
            puts "   vkit fetch --grant #{result["grant_ref"]}"
            exit 0

          when "ok"
            rows = result["rows"]
            meta = result["meta"] || {}

            unless rows.is_a?(Array)
              raise "Invalid response: expected rows to be an array"
            end

            puts "✅ OK — #{rows.size} rows"
            puts "Grant Ref: #{result["grant_ref"]} (reused)" if result["grant_ref"]
            print_request_id(result)

            if meta.any?
              puts "ℹ️  Query Metadata:"
              puts JSON.pretty_generate(meta)
            end

            puts
            puts "ℹ️  Data Rows:"
            Vkit::Core::TableFormatter.render(rows)
            exit 0

          else
            puts "❓ Unexpected response:"
            puts result.inspect
            print_request_id(result) if result.is_a?(Hash)
            exit 1
          end
        end
      end
    end
  end
end

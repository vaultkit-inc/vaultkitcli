# frozen_string_literal: true

require "json"
require "time"
require_relative "../../core/table_formatter"

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

        def handle_result(result, options)
          status = result["status"]

          if options[:format] == "json"
            puts JSON.pretty_generate(result)
            exit status == "denied" ? 2 : 0
          end

          case status
          when "denied"
            puts "❌ DENIED"
            puts "Reason: #{result["reason"]}"
            exit 2

          when "queued"
            puts "⏳ QUEUED for approval"
            puts "Request ID: #{result["request_id"]}"
            exit 0

          when "granted"
            expires_at = Time.parse(result["expires_at"]).getlocal

            puts "✅ ACCESS GRANTED"
            puts "Grant ID: #{result["grant_id"]}"
            puts "Expires: #{expires_at.strftime("%Y-%m-%d %H:%M:%S %Z")}"

            if (mask = result["masked_fields"]) && mask.any?
              puts "Masked Fields: #{mask.join(', ')}"
            else
              puts "Masked Fields: none"
            end

            puts
            puts "To execute and retrieve the data, run:"
            puts "   vkit fetch --grant #{result["grant_ref"] || result["grant_id"]}"
            exit 0

          when "ok"
            rows = result["rows"]
            meta = result["meta"] || {}

            unless rows.is_a?(Array)
              raise "Invalid response: expected rows to be an array"
            end

            puts "✅ OK — #{rows.size} rows"

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
            exit 1
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require "json"
require_relative "../api/client"
require_relative "../../core/credential_store"
require_relative "../../core/table_formatter"

module Vkit
  module CLI
    module Commands
      class RequestCommand
        def initialize(api_url: ENV["VKIT_API_URL"])
          raise "VKIT_API_URL not set" unless api_url
          @api_url = api_url.chomp("/")
        end

        def call(aql_str, options)
          user  = require_login!
          token = require_token!
          org   = user["organization_slug"]

          aql =
            if aql_str&.strip&.length&.positive?
              JSON.parse(aql_str)
            else
              JSON.parse(STDIN.read)
            end

          response = client.post(
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
        rescue JSON::ParserError
          raise "Invalid JSON AQL"
        rescue Vkit::CLI::API::APIError => e
          warn "❌ Request failed"
          warn e.message
          exit 1
        end

        private

        def client
          @client ||= Vkit::CLI::API::Client.new(
            base_url: @api_url,
            token: require_token!
          )
        end

        def require_login!
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

        def handle_result(result, options)
          if options[:format] == "json"
            puts JSON.pretty_generate(result)
            exit result["status"] == "denied" ? 2 : 0
          end

          status = result["status"]

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
            expires_at =
              Time.parse(result["expires_at"]).getlocal
            puts "✅ ACCESS GRANTED"
            puts "Grant ID: #{result["grant_id"]}"
            puts "Expires: #{expires_at.strftime("%Y-%m-%d %H:%M:%S %Z")}"
            if (mask = result["masked_fields"]) && mask.any?
              puts "Masked Fields: #{mask.join(', ')}"
            else
              puts "Masked Fields: none"
            end
        
            puts "\nTo execute and retrieve the data, run:"
            puts "   vkit fetch --grant #{result["grant_ref"] || result["grant_id"]}"
            exit 0

          when "ok"
            rows = result["rows"] || []

            puts "✅ OK — #{rows.size} rows"

            case options[:format]
            when "json"
              puts JSON.pretty_generate(rows)
            when "table"
              puts "ℹ️  Query Metadata:"
              puts JSON.pretty_generate(result["meta"] || {})
              puts "\nℹ️  Data Rows:"
              Vkit::Core::TableFormatter.render(rows)
            end

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

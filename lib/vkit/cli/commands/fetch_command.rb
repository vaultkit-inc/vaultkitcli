# frozen_string_literal: true

require "json"

module Vkit
  module CLI
    module Commands
      class FetchCommand < BaseCommand
        def call(grant_ref:, format: "json")
          with_auth do
            user = credential_store.user
            org  = user["organization_slug"]

            response = authenticated_client.post(
              "/api/v1/orgs/#{org}/grants/#{grant_ref}/fetch",
              body: {}
            )

            rows, meta = normalize_response(response)

            print_result(rows, meta, format)
          end
        end

        private

        def print_result(rows, meta, format)
          puts "✅ OK — #{rows.size} rows"

          if meta.any?
            puts "ℹ️  Query Metadata:"
            puts JSON.pretty_generate(meta)
          end

          case format
          when "json"
            puts JSON.pretty_generate(rows)
          when "table"
            Vkit::Core::TableFormatter.render(rows)
          else
            raise "Unknown format: #{format}"
          end
        end

        def normalize_response(response)
          rows =
            if response["rows"].is_a?(Array)
              response["rows"]
            else
              response.dig("rows", "rows") || []
            end
        
          meta =
            if response["meta"].is_a?(Hash)
              response["meta"]
            else
              response.dig("rows", "meta") || {}
            end
        
          [rows, meta]
        end
      end
    end
  end
end

# frozen_string_literal: true

require "json"
require_relative "../../core/table_formatter"

module Vkit
  module CLI
    module Commands
      class AgentTokensListCommand < BaseCommand
        def call(options)
          format = options[:format] || "table"

          with_auth do
            user = credential_store.user
            org  = user["organization_slug"]

            response =
              authenticated_client.get(
                "/api/v1/orgs/#{org}/agent_tokens",
                params: build_query(options)
              )

            tokens = response["tokens"] || []

            print_result(tokens, format)
          end
        end

        private

        def build_query(options)
          {}.tap do |q|
            q[:name] = options[:agent] if options[:agent]
          end
        end

        def print_result(tokens, format)
          if tokens.empty?
            puts "No tokens found."
            return
          end

          case format
          when "json"
            puts JSON.pretty_generate(tokens)

          when "table"
            Vkit::Core::TableFormatter.render(
              tokens.map do |t|
                {
                  "ID"         => t["id"],
                  "Agent"      => t["name"],
                  "Prefix"     => t["prefix"],
                  "Expires At" => t["expires_at"] || "never",
                  "Revoked At" => t["revoked_at"] || "-",
                  "Created At" => t["created_at"]
                }
              end
            )

          else
            raise "Unknown format: #{format}"
          end
        end
      end
    end
  end
end

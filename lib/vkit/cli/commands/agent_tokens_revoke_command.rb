# frozen_string_literal: true

require "json"

module Vkit
  module CLI
    module Commands
      class AgentTokensRevokeCommand < BaseCommand
        def call(options)
          token_ref = options.fetch(:token)

          with_auth do
            user = credential_store.user
            org  = user["organization_slug"]

            token = resolve_token!(org, token_ref)

            unless options[:force]
              confirm!(token)
            end

            authenticated_client.post(
              "/api/v1/orgs/#{org}/agent_tokens/#{token["id"]}/revoke",
              body: {}
            )

            puts "🛑 AGENT TOKEN REVOKED"
            puts
            puts "🧠 Name:   #{token["name"]}"
            puts "🏷  Prefix: #{token["prefix"]}"
            puts "🆔 ID:     #{token["id"]}"
            puts
            puts "✅ The token is no longer valid."
          end
        end

        private

        def resolve_token!(org, token_ref)
          response =
            authenticated_client.get(
              "/api/v1/orgs/#{org}/agent_tokens"
            )

          tokens = response["tokens"] || []

          token =
            tokens.find do |t|
              t["id"] == token_ref || t["prefix"] == token_ref
            end

          raise "Agent token not found: #{token_ref}" unless token

          token
        end

        def confirm!(token)
          puts "⚠️  You are about to revoke this agent token:"
          puts
          puts "🧠 Name:   #{token["name"]}"
          puts "🏷  Prefix: #{token["prefix"]}"
          puts "🆔 ID:     #{token["id"]}"
          puts
          print "\nType 'revoke' to confirm: "

          input = STDIN.gets&.strip
          abort "Aborted." unless input == "revoke"
        end
      end
    end
  end
end

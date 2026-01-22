# frozen_string_literal: true

require "json"
require "time"

module Vkit
  module CLI
    module Commands
      class AgentTokensCreateCommand < BaseCommand
        def call(options)
          with_auth do
            user = credential_store.user
            org  = user["organization_slug"]

            response =
              authenticated_client.post(
                "/api/v1/orgs/#{org}/agent_tokens",
                body: build_body(options)
              )

            token  = response.fetch("token")
            secret = response.fetch("secret")

            puts "🔐 AGENT TOKEN ISSUED (shown once)"
            puts

            puts "🧠 Name:       #{token["name"]}"
            puts "🎭 Role:       #{token["role"]}"
            puts "🆔 Token ID:   #{token["id"]}"
            puts "🏷  Prefix:     #{token["prefix"]}"
            puts "⏳ Expires At: #{token["expires_at"] || "never"}"
            puts

            puts "🔑 TOKEN"
            puts "────────────────────────────────────────"
            puts secret
            puts "────────────────────────────────────────"
            puts

            puts "⚠️  Store this token securely. It cannot be retrieved again."
          end
        end

        private

        def build_body(options)
          body = {
            name: options.fetch(:name),
            role: options[:role],
          }

          if options[:expires_in]
            body[:expires_at] = parse_expires_in(options[:expires_in]).iso8601
          end

          body
        end

        def parse_expires_in(value)
          number = value.to_i
        
          case value
          when /\A\d+h\z/
            Time.now.utc + (number * 60 * 60)
          when /\A\d+d\z/
            Time.now.utc + (number * 24 * 60 * 60)
          else
            raise "Invalid expires_in format (use 1h, 24h, 30d)"
          end
        end        
      end
    end
  end
end

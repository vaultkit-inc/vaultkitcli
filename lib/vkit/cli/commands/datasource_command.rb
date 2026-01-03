# frozen_string_literal: true

require "json"
require_relative "../api/client"
require_relative "../../core/credential_store"

module Vkit
  module CLI
    module Commands
      class DatasourceCommand
        REDACT = "[REDACTED]"

        def initialize(api_url: ENV["VKIT_API_URL"])
          @api_url = api_url&.chomp("/")
        end

        # ADD DATASOURCE
        def add(id:, engine:, username:, password:, config:)
          user = require_admin!
          org  = user["organization_slug"]

          config_hash = config ? JSON.parse(config) : {}

          response = client.post(
            "/api/v1/orgs/#{org}/datasources",
            body: {
              name: id,
              engine: engine,
              username: username,
              password: password,
              config: config_hash
            }
          )

          puts "✅ Datasource created:"
          print_datasource(response)

        rescue Vkit::CLI::API::APIError => e
          puts "❌ Failed to add datasource"
          puts e.message
          exit 1
        end
        
        def list
          user = require_admin!
          org  = user["organization_slug"]

          rows = client.get(
            "/api/v1/orgs/#{org}/datasources"
          )

          puts "📦 Datasources (#{rows.size}):"
          rows.each do |ds|
            print_datasource(ds)
            puts "-" * 40
          end

        rescue Vkit::CLI::API::APIError => e
          puts "❌ Failed to list datasources"
          puts e.message
          exit 1
        end
        
        def get(name)
          user = require_admin!
          org  = user["organization_slug"]

          ds = client.get(
            "/api/v1/orgs/#{org}/datasources/#{name}"
          )

          print_datasource(ds)

        rescue Vkit::CLI::API::APIError => e
          puts "❌ Failed to fetch datasource"
          puts e.message
          exit 1
        end

        
        # Helpers
        
        private

        def client
          unless @api_url
            raise Vkit::CLI::ConfigError,
                  "VKIT_API_URL not set.\n\n" \
                  "Set it using:\n" \
                  "  export VKIT_API_URL=https://api.vaultkit.io"
          end

          @client ||= Vkit::CLI::API::Client.new(
            base_url: @api_url,
            token: require_token!
          )
        end

        def require_admin!
          creds = Vkit::Core::CredentialStore.new
          user  = creds.load_user
          raise "Not logged in. Run: vkit login" unless user

          unless user["role"] == "admin"
            raise "⛔ Access denied: only admin users may manage datasources"
          end

          user
        end

        def require_token!
          creds = Vkit::Core::CredentialStore.new
          token = creds.load_token
          raise "Missing auth token. Run: vkit login" unless token
          token
        end

        def print_datasource(ds)
          puts JSON.pretty_generate(
            {
              name: ds["name"] || ds[:name],
              engine: ds["engine"] || ds[:engine],
              config: ds["config"] || ds[:config],
              username: REDACT,
              password: REDACT,
              created_at: ds["created_at"] || ds[:created_at],
              updated_at: ds["updated_at"] || ds[:updated_at]
            }
          )
        end
      end
    end
  end
end

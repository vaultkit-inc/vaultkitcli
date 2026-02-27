# frozen_string_literal: true

require "json"

module Vkit
  module CLI
    module Commands
      class DatasourceCommand < BaseCommand
        REDACT = "[REDACTED]"

        def add(id:, engine:, username:, password:, config:, region:, environment:)
          with_auth do
            user = require_admin!
            org  = user["organization_slug"]
        
            config_hash = config ? JSON.parse(config) : {}
        
            response = authenticated_client.post(
              "/api/v1/orgs/#{org}/datasources",
              body: {
                name: id,
                engine: engine,
                username: username,
                password: password,
                region: region.upcase,
                environment: environment,
                config: config_hash
              }
            )
        
            puts "✅ Datasource created:"
            print_datasource(response)
          end
        end        

        def list
          with_auth do
            user = require_admin!
            org  = user["organization_slug"]

            rows = authenticated_client.get(
              "/api/v1/orgs/#{org}/datasources"
            )

            puts "📦 Datasources (#{rows.size}):"
            rows.each do |ds|
              print_datasource(ds)
              puts "-" * 40
            end
          end
        end

        def get(name)
          with_auth do
            user = require_admin!
            org  = user["organization_slug"]

            ds = authenticated_client.get(
              "/api/v1/orgs/#{org}/datasources/#{name}"
            )

            print_datasource(ds)
          end
        end

        private

        def require_admin!
          user = credential_store.user
          raise "Not logged in. Run: vkit login" unless user

          unless user["role"] == "admin"
            raise "⛔ Access denied: only admin users may manage datasources"
          end

          user
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

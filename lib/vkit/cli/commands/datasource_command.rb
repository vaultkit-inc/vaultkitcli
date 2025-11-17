require "json"
require_relative "../../core/datasource_store"
require_relative "../../core/credential_store"

module Vkit
  module CLI
    module Commands
      class DatasourceCommand
        REDACT = "[REDACTED]"

        def initialize
          @store = Vkit::Core::DatasourceStore.new
        end

        ####################################################################
        # Add a new datasource (MVP: store credentials directly)
        ####################################################################
        def add(id:, engine:, username:, password:, config:)
          require_admin!

          config_hash = config ? JSON.parse(config) : {}

          ds = @store.add!(
            id: id,
            engine: engine,
            username: username,
            password: password,
            config: config_hash
          )

          puts "✅ Datasource created:"
          print_datasource(ds)
        rescue => e
          puts "❌ Failed to add datasource"
          puts e.message
          exit 1
        end

        ####################################################################
        # List (redacted)
        ####################################################################
        def list
          require_admin!

          rows = @store.list
          puts "📦 Datasources (#{rows.size}):"
          rows.each do |ds|
            print_datasource(ds)
            puts "-" * 40
          end
        rescue => e
          puts "❌ Failed to list datasources: #{e.message}"
          exit 1
        end

        ####################################################################
        # Get (redacted)
        ####################################################################
        def get(id)
          require_admin!

          ds = @store.fetch(id)
          raise "Datasource not found: #{id}" unless ds

          print_datasource(ds)
        rescue => e
          puts "❌ Failed to fetch datasource: #{e.message}"
          exit 1
        end

        ####################################################################
        # Helper Methods
        ####################################################################
        private

        def require_admin!
          creds = Vkit::Core::CredentialStore.new
          user = creds.load_user
          raise "Not logged in. Run: vkit login" if user.nil?

          unless user["role"] == "admin"
            raise "⛔ Access denied: only admin users may manage datasources"
          end

          user
        end

        def print_datasource(ds)
          puts JSON.pretty_generate(
            {
              id: ds[:id],
              engine: ds[:engine],
              config: ds[:config],
              username: REDACT,
              password: REDACT,
              created_at: ds[:created_at],
              updated_at: ds[:updated_at]
            }
          )
        end
      end
    end
  end
end

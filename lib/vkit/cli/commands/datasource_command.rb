require "json"
require_relative "../../core/datasource_store"
require_relative "../../core/credential_store"
require_relative "../../core/audit_logger"

module Vkit
  module CLI
    module Commands
      class DatasourceCommand
        REDACT = "[REDACTED]"

        def initialize
          @store = Vkit::Core::DatasourceStore.new
        end

        ####################################################################
        # ADD DATASOURCE
        ####################################################################
        def add(id:, engine:, username:, password:, config:)
          user = require_admin!
          actor = user["email"]

          config_hash = config ? JSON.parse(config) : {}

          ds = @store.add!(
            id: id,
            engine: engine,
            username: username,
            password: password,
            config: config_hash
          )

          # AUDIT EVENT
          Vkit::Core::AuditLogger.log(
            event: "datasource.created",
            actor: actor,
            details: {
              id: id,
              engine: engine,
              config_keys: config_hash.keys
            }
          )

          puts "✅ Datasource created:"
          print_datasource(ds)

        rescue => e
          puts "❌ Failed to add datasource"
          puts e.message

          # AUDIT FAILURE
          Vkit::Core::AuditLogger.log(
            event: "datasource.create_failed",
            actor: actor,
            details: { id: id, error: e.message }
          )

          exit 1
        end

        ####################################################################
        # LIST
        ####################################################################
        def list
          user = require_admin!
          actor = user["email"]

          rows = @store.list
          puts "📦 Datasources (#{rows.size}):"
          rows.each do |ds|
            print_datasource(ds)
            puts "-" * 40
          end

          # AUDIT
          Vkit::Core::AuditLogger.log(
            event: "datasource.listed",
            actor: actor,
            details: { count: rows.size }
          )

        rescue => e
          puts "❌ Failed to list datasources: #{e.message}"

          Vkit::Core::AuditLogger.log(
            event: "datasource.list_failed",
            actor: actor,
            details: { error: e.message }
          )
          exit 1
        end

        ####################################################################
        # GET (view)
        ####################################################################
        def get(id)
          user = require_admin!
          actor = user["email"]

          ds = @store.fetch(id)
          raise "Datasource not found: #{id}" unless ds

          print_datasource(ds)

          # AUDIT
          Vkit::Core::AuditLogger.log(
            event: "datasource.viewed",
            actor: actor,
            details: { id: id, engine: ds[:engine] }
          )

        rescue => e
          puts "❌ Failed to fetch datasource: #{e.message}"

          Vkit::Core::AuditLogger.log(
            event: "datasource.view_failed",
            actor: actor,
            details: { id: id, error: e.message }
          )

          exit 1
        end

        ####################################################################
        # Helpers
        ####################################################################
        private

        def require_admin!
          creds = Vkit::Core::CredentialStore.new
          user  = creds.load_user
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

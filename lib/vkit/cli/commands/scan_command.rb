# lib/vkit/cli/commands/scan_command.rb
require "yaml"
require_relative "../../core/dataset_scanner"
require_relative "../../core/classifier"
require_relative "../../core/registry_updater"
require_relative "../../core/audit_logger"
require_relative "../../core/credential_store"

module Vkit
  module CLI
    module Commands
      class ScanCommand
        def initialize
          @audit = Vkit::Core::AuditLogger
        end

        def call(datasource_id)
          user = require_login!
          actor = user["email"]

          puts "🔍 Scanning datasource '#{datasource_id}'..."

          scanner     = Vkit::Core::DatasetScanner.new(datasource_id: datasource_id)
          raw_schema  = scanner.scan

          puts raw_schema

          puts "🧠 Classifying fields..."
          classifier  = Vkit::Core::Classifier.new
          classified  = classifier.classify(raw_schema)

          puts "📝 Updating registry..."
          updater          = Vkit::Core::RegistryUpdater.new
          updated_registry = updater.update(
            classified,
            datasource_id: datasource_id
          )

          # Convert classifier array → hash for audit logging
          classified_hash = classified.each_with_object({}) do |entry, h|
            table = entry[:table] || entry["table"]
            cols  = entry[:columns] || entry["columns"]
            h[table] = cols
          end

          @audit.log(
            event:  "scan.completed",
            actor:  actor,
            details: {
              datasource: datasource_id,
              tables: raw_schema.keys,
              classified_fields: classified_hash.transform_values { |cols| cols.map { |c| c[:name] } }
            }
          )


          puts "✅ Scan complete!"
          puts "📘 Updated registry.yaml"
          puts "─" * 50
          puts YAML.dump(updated_registry)
          puts "─" * 50

        rescue => e
          @audit.log(
            event:  "scan.failed",
            actor:  require_login_safe,
            details: { datasource: datasource_id, error: e.message }
          )
          warn "❌ Scan failed: #{e.message}"
          exit 1
        end

        private

        def require_login!
          creds = Vkit::Core::CredentialStore.new
          user  = creds.load_user
          raise "Not logged in. Run: vkit login" if user.nil?
          user
        end

        # fallback when logging failure events and login failed
        def require_login_safe
          creds = Vkit::Core::CredentialStore.new
          user  = creds.load_user
          user ? user["email"] : "unknown"
        end
      end
    end
  end
end

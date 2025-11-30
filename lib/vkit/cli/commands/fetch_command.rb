require "json"
require_relative "../../core/funl_client"
require_relative "../../core/grant_store"
require_relative "../../core/table_formatter"
require_relative "../../core/dataset_registry"
require_relative "../../core/credential_resolver"
require_relative "../../core/audit_logger"

module Vkit
  module CLI
    module Commands
      class FetchCommand
        def initialize(funl_url: ENV["FUNL_URL"])
          @funl_url = funl_url
        end

        def call(grant_id:, format: "json")
          creds = Vkit::Core::CredentialStore.new
          user  = creds.load_user
          raise "Not logged in. Run: vkit login" if user.nil?

          actor = user["email"]

          grant = Vkit::Core::GrantStore.new.fetch(grant_id)
          raise "Grant not found: #{grant_id}" unless grant

          if grant[:requester] != actor
            raise "Access denied: you do not have permission to use this grant"
          end

          if expired?(grant)
            raise "Grant expired at #{grant[:expires_at]}"
          end

          dataset_info  = Vkit::Core::DatasetRegistry.load(grant[:dataset])
          datasource_id = dataset_info[:datasource]

          resolver = Vkit::Core::CredentialResolver.new
          datasource = resolver.resolve(datasource_id)

          client = Vkit::Core::FunlClient.new(base_url: @funl_url)
          response = client.execute(
            aql: {
              "source_table" => grant[:dataset],
              "columns" => grant[:fields]
            },
            bearer: grant[:session_token],
            datasource: datasource,
            options: {
              mask_fields: grant[:mask_fields]
            }
          )

          rows = response["rows"] || []
          meta = response["meta"] || {}

          # --------------------------
          # AUDIT LOG: fetch event
          # --------------------------
          Vkit::Core::AuditLogger.log(
            event: "fetch.executed",
            actor: actor,
            details: {
              grant_id: grant_id,
              dataset: grant[:dataset],
              fields: grant[:fields],
              masked_fields: grant[:mask_fields],
              datasource: datasource_id,
              row_count: rows.size,
              funl_url: @funl_url
            }
          )

          print_result(rows, meta, format)

        rescue => e
          # audit failure too
          Vkit::Core::AuditLogger.log(
            event: "fetch.failed",
            actor: actor,
            details: {
              grant_id: grant_id,
              error: e.message
            }
          )
          puts "❌ Fetch failed: #{e.message}"
          exit 1
        end

        private

        def expired?(grant)
          Time.parse(grant[:expires_at]) <= Time.now
        end

        def print_result(rows, meta, format)
          puts "✅ OK — rows: #{rows.size}"
          puts "ℹ️  Query Metadata:"
          puts JSON.pretty_generate(meta)

          case format
          when "json"
            puts JSON.pretty_generate(rows)
          when "table"
            Vkit::Core::TableFormatter.render(rows)
          else
            raise "Unknown format: #{format}"
          end
        end
      end
    end
  end
end

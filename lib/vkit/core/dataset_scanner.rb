# lib/vkit/core/dataset_scanner.rb
require_relative "credential_resolver"
require_relative "funl_client"
require_relative "credential_store"
require_relative 'jwt_encoder'

module Vkit
  module Core
    class DatasetScanner

      def initialize(datasource_id:)
        @datasource_id = datasource_id
        @resolver = CredentialResolver.new
        @client   = FunlClient.new
      end

      # Returns:
      # {
      #   "customers" => [{name: "id", type: "integer"}, ...],
      #   "orders"    => [...]
      # }
      def scan
        datasource = @resolver.resolve(@datasource_id)
        raise "Unknown datasource: #{@datasource_id}" unless datasource

        session_token = Vkit::Core::JwtEncoder.issue_internal_token(
          role: "schema_scanner",
          datasource: @datasource_id,
          expires_at: Time.now.utc + 60  # 1 minute TTL
        )

        tables = fetch_tables(datasource, session_token)
        schema = {}

        tables.each do |row|
          table_name = row["table_name"] || row[:table_name]
          next unless table_name

          schema[table_name] = fetch_columns(datasource, table_name, session_token)
        end

        schema
      end

      private

      def fetch_tables(ds, token)
        @client.introspect_tables(
          datasource: ds,
          bearer:     token
        )
      end

      def fetch_columns(ds, table, token)
        rows = @client.introspect_columns(
          datasource: ds,
          table:      table,
          bearer:     token
        )

        rows.map do |row|
          {
            name: row["column_name"] || row[:column_name],
            type: row["data_type"]   || row[:data_type]
          }
        end
      end
    end
  end
end

require "sqlite3"
require "json"
require "securerandom"
require "time"
require_relative 'jwt_encoder'

module Vkit
  module Core
    class GrantStore
      DEFAULT_PATH = "data/grants.db"

      def initialize(path: DEFAULT_PATH)
        @db = SQLite3::Database.new(path)
        @db.results_as_hash = true
        create_table
      end

      # Create table if not exists (idempotent)
      def create_table
        @db.execute <<~SQL
          CREATE TABLE IF NOT EXISTS grants (
            id TEXT PRIMARY KEY,
            requester TEXT,
            dataset TEXT,
            fields TEXT,            -- JSON array
            mask_fields TEXT,       -- JSON array of masked fields
            decision TEXT,          -- "allow" or "mask"
            policy_id TEXT,
            reason TEXT,
            ttl_seconds INTEGER,
            issued_at TEXT,
            expires_at TEXT,
            session_token TEXT       -- short-lived token sent to Funl
          );
        SQL

        @db.execute("CREATE INDEX IF NOT EXISTS idx_grants_requester ON grants(requester)")
        @db.execute("CREATE INDEX IF NOT EXISTS idx_grants_expires ON grants(expires_at)")
      end

      # Issue a new grant
      def issue!(request:, decision:, policy_id:, reason:, ttl_seconds:)
        now        = Time.now.utc
        id         = "grant_" + SecureRandom.hex(8)
        expires_at = now + ttl_seconds.to_i

        fields_json      = JSON.dump(request[:fields])
        mask_fields_json = JSON.dump(request[:mask_fields] || [])

        session = Vkit::Core::JwtEncoder.issue_session_token(
          user: request[:requester],
          grant_id: id,
          expires_at: expires_at
        )

        @db.execute(
          <<~SQL,
            INSERT INTO grants (
              id, requester, dataset, fields, mask_fields,
              decision, policy_id, reason, ttl_seconds,
              issued_at, expires_at, session_token
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          [
            id,
            request[:requester],
            request[:dataset],
            fields_json,
            mask_fields_json,
            decision,
            policy_id,
            reason,
            ttl_seconds,
            now.iso8601,
            expires_at.iso8601,
            session
          ]
        )

        fetch(id)
      end

      # Update mask fields (only for mask grants)
      def update_mask_fields!(id, mask_fields)
        json = JSON.dump(mask_fields || [])
        @db.execute("UPDATE grants SET mask_fields=? WHERE id=?", [json, id])
      end

      # Find a valid (unexpired) grant that fully covers this request
      def find_valid(request:)
        rows = @db.execute(
          "SELECT * FROM grants WHERE requester=? AND dataset=? ORDER BY issued_at DESC",
          [request[:requester], request[:dataset]]
        )

        now = Time.now.utc
        req_fields = request[:fields]

        rows.each do |r|
          next if Time.parse(r["expires_at"]) <= now

          granted_fields = JSON.parse(r["fields"])
          # Grant must include all requested fields
          return to_hash(r) if (req_fields - granted_fields).empty?
        end

        nil
      end

      # ------------------------------------------------------------
      # Fetch by ID
      # ------------------------------------------------------------
      def fetch(id)
        row = @db.get_first_row("SELECT * FROM grants WHERE id=?", [id])
        row && to_hash(row)
      end

      # List all grants (or by requester)
      def list(requester: nil)
        sql = "SELECT * FROM grants"
        args = []

        if requester
          sql << " WHERE requester=?"
          args << requester
        end

        @db.execute(sql, args).map { |r| to_hash(r) }
      end

      private

      # Convert SQLite row into a Ruby hash with parsed JSON
      def to_hash(row)
        {
          id:           row["id"],
          requester:    row["requester"],
          dataset:      row["dataset"],
          fields:       safe_parse_json(row["fields"]),
          mask_fields:  safe_parse_json(row["mask_fields"]),
          decision:     row["decision"],
          policy_id:    row["policy_id"],
          reason:       row["reason"],
          ttl_seconds:  row["ttl_seconds"],
          issued_at:    row["issued_at"],
          expires_at:   row["expires_at"],
          session_token: row["session_token"]
        }
      end

      def safe_parse_json(value)
        return [] if value.nil? || value.strip == ""
        JSON.parse(value)
      rescue
        []
      end
    end
  end
end

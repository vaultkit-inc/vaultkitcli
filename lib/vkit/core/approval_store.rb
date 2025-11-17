# lib/vkit/core/approval_store.rb
require "sqlite3"
require "json"
require "time"
require_relative "grant_store"

module Vkit
  module Core
    class ApprovalStore
      def initialize(path: "data/approvals.db")
        @db = SQLite3::Database.new(path)
        @db.results_as_hash = true
        create_table
      end

      def create_table
        @db.execute <<~SQL
          CREATE TABLE IF NOT EXISTS approvals (
            id TEXT PRIMARY KEY,
            dataset TEXT,
            fields TEXT,           -- JSON array
            requester TEXT,
            approver_role TEXT,
            reason TEXT,
            state TEXT,             -- pending, approved, denied
            created_at TEXT,
            approved_at TEXT
          );
        SQL
      end

      def enqueue(request, reason:, approver_role:)
        id = "req_" + SecureRandom.hex(6)
        @db.execute(
          "INSERT INTO approvals (id, dataset, fields, requester, approver_role, reason, state, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
          [id, request[:dataset], JSON.dump(request[:fields]), request[:requester], approver_role, reason, "pending", Time.now.utc.iso8601]
        )
        id
      end

      def approve!(id, approver:, ttl_seconds: 3600)
        row = fetch(id)
        raise "Request not found" unless row
        raise "Request already #{row[:state]}" unless row[:state] == "pending"

        grant_store = Vkit::Core::GrantStore.new
        fields = row[:fields].is_a?(String) ? JSON.parse(row[:fields]) : row[:fields]

        grant = grant_store.issue!(
          request: {
            requester: row[:requester],
            dataset: row[:dataset],
            fields: fields
          },
          decision: "allow",
          policy_id: "approval_flow",
          reason: "Approved by #{approver}",
          ttl_seconds: ttl_seconds
        )

        @db.execute(
          "UPDATE approvals SET state=?, approved_at=? WHERE id=?",
          ["approved", Time.now.utc.iso8601, id]
        )

        grant
      end

      def deny!(id, approver:)
        @db.execute(
          "UPDATE approvals SET state=?, approved_at=? WHERE id=?",
          ["denied", Time.now.utc.iso8601, id]
        )
      end

      def list(state: nil)
        q = "SELECT * FROM approvals"
        args = []
        if state
          q << " WHERE state=?"
          args << state
        end
        @db.execute(q, args).map { |r| to_hash(r) }
      end

      def fetch(id)
        row = @db.get_first_row("SELECT * FROM approvals WHERE id=?", [id])
        row && to_hash(row)
      end

      def list_for_user(email)
        rows = @db.execute("SELECT * FROM approvals WHERE requester = ? ORDER BY created_at DESC", [email])
        rows.map { |r| to_hash(r) }
      end

      def fetch_for_user(id, email)
        row = @db.get_first_row("SELECT * FROM approvals WHERE id = ? AND requester = ?", [id, email])
        row && to_hash(row)
      end

      private

      def to_hash(r)
        {
          id: r["id"],
          dataset: r["dataset"],
          fields: JSON.parse(r["fields"]),
          requester: r["requester"],
          approver_role: r["approver_role"],
          reason: r["reason"],
          state: r["state"],
          created_at: r["created_at"],
          approved_at: r["approved_at"]
        }
      end
    end
  end
end

require "sqlite3"
require "json"

module Vkit
  module Core
    module AuditSinks
      class SqliteSink
        DEFAULT_PATH = "data/audit_logs.db"

        def initialize(path: DEFAULT_PATH)
          @db = SQLite3::Database.new(path)
          @db.results_as_hash = true
          create_table
        end

        def create_table
          @db.execute <<~SQL
            CREATE TABLE IF NOT EXISTS audit_logs (
              id TEXT PRIMARY KEY,
              event TEXT,
              actor TEXT,
              details TEXT,
              timestamp TEXT
            );
          SQL
        end

        def write(entry)
          @db.execute(
            "INSERT INTO audit_logs (id, event, actor, details, timestamp)
             VALUES (?, ?, ?, ?, ?)",
            [
              entry[:id],
              entry[:event],
              entry[:actor],
              JSON.dump(entry[:details]),
              entry[:timestamp]
            ]
          )
        end
      end
    end
  end
end

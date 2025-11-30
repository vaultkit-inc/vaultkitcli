require "json"
require_relative "audit_sinks/sqlite_sink"

module Vkit
  module Core
    class AuditLogger
      @sinks = [
        AuditSinks::SqliteSink.new # currently only SQLite
      ]

      class << self
        # event: "grant.issued"
        # actor: "user@example.com"
        # details: Hash
        def log(event:, actor:, details: {})
          entry = {
            id: "audit_" + SecureRandom.hex(8),
            event: event,
            actor: actor,
            details: details,
            timestamp: Time.now.utc.iso8601
          }

          @sinks.each { |sink| sink.write(entry) }
          entry
        end

        def sink(s)
          @sinks << s
        end
      end
    end
  end
end

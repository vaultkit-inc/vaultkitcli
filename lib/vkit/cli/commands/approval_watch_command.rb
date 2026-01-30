# frozen_string_literal: true

require "json"
require "time"

module Vkit
  module CLI
    module Commands
      class ApprovalWatchCommand < BaseCommand
        DEFAULT_INTERVAL = 3

        def call(interval: DEFAULT_INTERVAL, format: "table", pretty: false, since: nil)
          with_auth do
            user = credential_store.user
            org  = user["organization_slug"]

            since_time = parse_since(since)
            seen = {}

            if format == "table"
              puts "⏳ Watching approval queue (Ctrl+C to stop)…"
              puts "Since: #{since_time.iso8601}" if since_time
              puts
            end

            loop do
              approvals =
                authenticated_client.get(
                  "/api/v1/orgs/#{org}/approvals",
                  params: build_query(since_time)
                )

              approvals.each do |approval|
                next if seen[approval["id"]]

                emit(approval, format, pretty)
                seen[approval["id"]] = true
              end

              sleep interval
            end
          end
        rescue Interrupt
          puts "\n👋 Watch stopped." if format == "table"
        end

        private

        def build_query(since_time)
          {}.tap do |q|
            q[:state] = "pending"
            q[:since] = since_time.iso8601 if since_time
          end
        end

        def parse_since(value)
          return nil if value.nil?
        
          now = Time.now.utc
        
          case value
          when /\A(\d+)m\z/
            now - Regexp.last_match(1).to_i * 60
          when /\A(\d+)h\z/
            now - Regexp.last_match(1).to_i * 60 * 60
          when /\A(\d+)d\z/
            now - Regexp.last_match(1).to_i * 60 * 60 * 24
          else
            Time.iso8601(value)
          end
        rescue ArgumentError
          raise "Invalid --since value (use ISO8601 or 10m, 2h, 1d)"
        end        

        def emit(approval, format, pretty)
          case format
          when "json"
            print_json(normalize(approval), pretty: pretty)
          when "table"
            render_human(approval)
          else
            raise "Unknown format: #{format}"
          end
        end

        def print_json(obj, pretty:)
          if pretty
            puts JSON.pretty_generate(obj)
          else
            puts JSON.generate(obj)
          end
        end

        def normalize(a)
          {
            type: "approval.pending",
            id: a["id"],
            dataset: a["dataset"],
            fields: a["fields"],
            requester: a["requester"],
            approver_role: a["approver_role"],
            created_at: a["created_at"]
          }
        end

        def render_human(a)
          puts "🔔 NEW APPROVAL"
          puts "────────────────────────────"
          puts "ID:        #{a["id"]}"
          puts "Dataset:   #{a["dataset"]}"
          puts "Fields:    #{Array(a["fields"]).join(", ")}"
          puts "Requester: #{a["requester"]}"
          puts "Role Req:  #{a["approver_role"] || "any"}"
          puts "Created:   #{format_time(a["created_at"])}"
          puts
          puts "▶ Approve: vkit approval approve #{a["id"]}"
          puts "▶ Deny:    vkit approval deny #{a["id"]} --reason \"…\""
          puts
        end

        def format_time(value)
          Time.parse(value).getlocal.strftime("%Y-%m-%d %H:%M:%S")
        rescue
          value
        end
      end
    end
  end
end

# frozen_string_literal: true

require "json"

module Vkit
  module CLI
    module Commands
      class ScanCommand < BaseCommand
        def call(datasource_name, mode: "diff_only")
          with_auth do
            user = credential_store.user
            org  = user["organization_slug"]

            puts "🔍 Running scan for datasource '#{datasource_name}' (mode=#{mode})..."

            response = authenticated_client.post(
              "/api/v1/orgs/#{org}/datasources/#{datasource_name}/scan",
              body: {
                datasource: datasource_name,
                mode: mode
              }
            )

            puts "✅ Scan completed"
            puts "🆔 Scan ID: #{response["scan_id"]}"
            puts "📌 Mode: #{response["mode"]}"

            diff = response["diff"] || {}

            if diff.empty?
              puts "✨ No changes detected"
            else
              puts "📐 Registry diff:"
              puts "─" * 50
              puts JSON.pretty_generate(diff)
              puts "─" * 50
            end

            if response.key?("applied")
              puts response["applied"] ? "✅ Changes applied" : "ℹ️ Changes not applied"
            end
          end
        end
      end
    end
  end
end

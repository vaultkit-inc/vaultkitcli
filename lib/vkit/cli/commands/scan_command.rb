# frozen_string_literal: true

require "json"
require_relative "../api/client"
require_relative "../../core/credential_store"

module Vkit
  module CLI
    module Commands
      class ScanCommand
        def initialize(api_url: ENV["VKIT_API_URL"])
          raise "VKIT_API_URL not set" unless api_url
          @api_url = api_url.chomp("/")
        end

        # mode: "diff_only" (default) or "apply"
        def call(datasource_name, mode: "diff_only")
          user  = require_login!
          org   = user["organization_slug"]

          puts "🔍 Running scan for datasource '#{datasource_name}' (mode=#{mode})..."

          response = client.post(
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

        rescue Vkit::CLI::API::APIError => e
          warn "❌ Scan failed"
          warn e.message
          exit 1
        end

        private

        def client
          @client ||= Vkit::CLI::API::Client.new(
            base_url: @api_url,
            token: require_token!
          )
        end

        def require_login!
          creds = Vkit::Core::CredentialStore.new
          user  = creds.load_user
          raise "Not logged in. Run: vkit login" unless user
          user
        end

        def require_token!
          creds = Vkit::Core::CredentialStore.new
          token = creds.load_token
          raise "Missing auth token. Run: vkit login" unless token
          token
        end
      end
    end
  end
end

# frozen_string_literal: true

require "json"
require_relative "../api/client"
require_relative "../../core/credential_store"
require_relative "../../core/table_formatter"

module Vkit
  module CLI
    module Commands
      class RequestsListCommand
        def initialize(api_url: ENV["VKIT_API_URL"])
          raise "VKIT_API_URL not set" unless api_url
          @api_url = api_url.chomp("/")
        end

        def call(state:, format:)
          user = require_login!
          org  = user["organization_slug"]

          params = {}
          params[:state] = state unless state == "all"

          response =
            client.get(
              "/api/v1/orgs/#{org}/requests",
              params: params
            )

          render(response, format)
        rescue Vkit::CLI::API::APIError => e
          warn "❌ Failed to list requests"
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

        def render(rows, format)
          if rows.empty?
            puts "📭 No requests found"
            return
          end

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

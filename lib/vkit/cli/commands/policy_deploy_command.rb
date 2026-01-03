# frozen_string_literal: true

require "json"
require_relative "../api/client"
require_relative "../../core/credential_store"

module Vkit
  module CLI
    module Commands
      class PolicyDeployCommand
        def call(bundle_path:, org:, server:, activate:)
          bundle_path = File.expand_path(bundle_path)
          raise "Bundle not found: #{bundle_path}" unless File.exist?(bundle_path)

          unless server
            raise Vkit::CLI::ConfigError,
              "VKIT_API_URL not set.\n\n" \
              "Set it using:\n" \
              "  export VKIT_API_URL=https://api.vaultkit.dev" \
          end

          bundle = JSON.parse(File.read(bundle_path))

          response = client(server).post(
            "/api/v1/orgs/#{org}/policy_bundles",
            body: {
              bundle: bundle,
              activate: activate
            }
          )

          puts "🚀 Policy bundle deployed"
          puts "   Version: #{response['bundle_version']}"
          puts "   State:   #{response['state']}"

        rescue Vkit::CLI::API::APIError => e
          puts "❌ Policy deploy failed"
          puts e.message
          exit 1
        end

        private

        def client(server)
          @clients ||= {}

          @clients[server] ||= Vkit::CLI::API::Client.new(
            base_url: server,
            token: require_token!
          )
        end

        def require_token!
          creds = Vkit::Core::CredentialStore.new
          token = creds.load_token
          raise "Not logged in. Run: vkit login" unless token
          token
        end
      end
    end
  end
end

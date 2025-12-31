require "json"
require "net/http"
require "uri"
require_relative "../../core/credential_resolver"

module Vkit
  module CLI
    module Commands
      class PolicyDeployCommand
        def call(bundle_path:, org:, server:, activate:)
          bundle_path = File.expand_path(bundle_path)
          raise "Bundle not found: #{bundle_path}" unless File.exist?(bundle_path)

          creds = Vkit::Core::CredentialStore.new
          token  = creds.load_token
          raise "Not logged in. Run: vkit login" if token.nil?

          bundle = JSON.parse(File.read(bundle_path))

          uri = URI("#{server}/api/v1/orgs/#{org}/policy_bundles")
          req = Net::HTTP::Post.new(uri)
          req["Authorization"] = "Bearer #{token}"
          req["Content-Type"] = "application/json"

          req.body = {
            bundle: bundle,
            activate: activate
          }.to_json

          res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
            http.request(req)
          end

          unless res.is_a?(Net::HTTPSuccess)
            raise "Deploy failed: #{res.code} #{res.body}"
          end

          body = JSON.parse(res.body)
          puts "🚀 Policy bundle deployed"
          puts "   Version: #{body["bundle_version"]}"
          puts "   State:   #{body["state"]}"
        end
      end
    end
  end
end

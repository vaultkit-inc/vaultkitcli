module Vkit
  module CLI
    module Commands
      class WhoamiCommand < BaseCommand
        def call
          user = fetch_user_from_server_or_fallback

          puts "👤 #{user['email']} " \
               "(role: #{user['role']}, org: #{user['organization_slug']})"
        end

        private

        def fetch_user_from_server_or_fallback
          token = credential_store.token
          endpoint = credential_store.endpoint

          raise "Not logged in" if token.nil? || endpoint.nil?

          client = Vkit::Core::AuthClient.new(base_url: endpoint)
          server_user = client.whoami(token)

          # keep cache in sync if server is authoritative
          credential_store.save_user(server_user)

          server_user
        rescue => e
          fallback_local_user(e)
        end

        def fallback_local_user(error)
          user = credential_store.user
          raise "Not logged in" if user.nil?

          warn "⚠️ Unable to verify identity with server"
          warn "⚠️ #{error.message}"
          warn "⚠️ Showing cached identity"

          user
        end
      end
    end
  end
end

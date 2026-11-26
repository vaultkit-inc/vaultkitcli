module Vkit
  module CLI
    module Commands
      class WhoamiCommand < BaseCommand
        def call
          user = fetch_user_from_server_or_fallback

          puts "👤 #{user['email']} " \
               "(role: #{user['role']}, org: #{user['organization_slug']})"
          respond({ "email" => user["email"], "role" => user["role"],
                    "organization" => user["organization_slug"], "endpoint" => credential_store.endpoint,
                    "verified" => !@cached })
        end

        private

        def fetch_user_from_server_or_fallback
          token = credential_store.token
          endpoint = credential_store.endpoint

          raise not_logged_in("Not logged in") if token.nil? || endpoint.nil?

          client = Vkit::Core::AuthClient.new(base_url: endpoint)
          server_user = client.whoami(token)

          # keep cache in sync if server is authoritative
          credential_store.save_user(server_user)

          server_user
        rescue => e
          # An agent checks the session with whoami, so a cached identity
          # would hide an expired or unreachable one.
          raise if json?

          fallback_local_user(e)
        end

        def fallback_local_user(error)
          user = credential_store.user
          raise not_logged_in("Not logged in") if user.nil?

          @cached = true

          warn "⚠️ Unable to verify identity with server"
          warn "⚠️ #{error.message}"
          warn "⚠️ Showing cached identity"

          user
        end
      end
    end
  end
end

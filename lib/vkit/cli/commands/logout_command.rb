module Vkit
  module CLI
    module Commands
      class LogoutCommand < BaseCommand
        # Always the saved login, even when VKIT_ENDPOINT/VKIT_TOKEN are set.
        def call
          saved = credential_store.stored_payload || {}
          token = saved["token"]

          if token
            begin
              client = Vkit::Core::AuthClient.new(
                base_url: saved["endpoint"]
              )

              client.logout(token)
            rescue => e
              warn "⚠️ Server logout failed: #{e.message}"
              warn "⚠️ Continuing with local logout"
            end
          end

          credential_store.clear_token!
          puts "🧹 Logged out"
        end
      end
    end
  end
end

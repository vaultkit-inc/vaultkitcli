module Vkit
  module CLI
    module Commands
      class LogoutCommand < BaseCommand
        def call
          token = credential_store.token

          if token
            begin
              client = Vkit::Core::AuthClient.new(
                base_url: credential_store.endpoint
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

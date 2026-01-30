module Vkit
  module CLI
    module Commands
      class LogoutCommand < BaseCommand
        def call
          credential_store.clear_token!
          puts "🧹 Logged out"
        end
      end
    end
  end
end

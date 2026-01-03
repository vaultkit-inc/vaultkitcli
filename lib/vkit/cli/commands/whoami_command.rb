module Vkit
  module CLI
    module Commands
      class WhoamiCommand < BaseCommand
        def call
          with_auth do
            user = credential_store.user
            puts "👤 #{user['email']} (role: #{user['role']}, org: #{user['organization_slug']})"
          end
        end
      end
    end
  end
end

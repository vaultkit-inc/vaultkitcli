require_relative "../api/client"

module Vkit
  module CLI
    module Commands
      class BaseCommand
        protected

        def with_auth
          return yield unless requires_auth?

          store = credential_store

          unless store.logged_in?
            raise "Not logged in. Run `vkit login`."
          end

          yield
        end

        def authenticated_client
          store = credential_store

          if requires_auth? && !store.logged_in?
            raise "Not logged in. Run `vkit login`."
          end

          Vkit::CLI::API::Client.new(
            base_url: store.endpoint,
            token: store.token
          )
        end

        def requires_auth?
          true
        end

        def credential_store
          @credential_store ||= Vkit::Core::CredentialStore.new
        end
      end
    end
  end
end

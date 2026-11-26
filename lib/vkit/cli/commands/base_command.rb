require_relative "../api/client"
require_relative "../errors"
require_relative "../output"
require_relative "../error_map"

module Vkit
  module CLI
    module Commands
      class BaseCommand
        NOT_LOGGED_IN = "Not logged in. Run `vkit login`."

        protected

        def with_auth
          return yield unless requires_auth?

          store = credential_store

          unless store.logged_in?
            raise not_logged_in
          end

          yield
        end

        def authenticated_client
          store = credential_store

          if requires_auth? && !store.logged_in?
            raise not_logged_in
          end

          Vkit::CLI::Output.register_secret(store.token)

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

        def not_logged_in(message = NOT_LOGGED_IN)
          Vkit::CLI::CommandError.new(message, code: "not_logged_in", fix: [Vkit::CLI::ErrorMap::LOGIN_FIX])
        end

        def json?
          Vkit::CLI::Output.json?
        end

        # Records the result for --format json (and returns it). Human
        # output is printed by the command as before.
        def respond(result, next_steps = [], exit_code: Vkit::CLI::Output::EXIT_OK)
          Vkit::CLI::Output.respond(result: result, next_steps: next_steps, exit_code: exit_code)
        end

        def needs_input!(code, message, fix, next_steps: [])
          raise Vkit::CLI::NeedsInput.new(message, code: code, fix: fix, next_steps: next_steps)
        end

        # A yes/no question for the person. Under --format json there's no
        # one to ask, so it's needs_input, naming the flag that answers it.
        def confirmation_needed!(what, flag)
          needs_input!("confirmation_required", "#{what} needs confirmation.",
                       ["Ask the person whether to go ahead; if they agree, rerun with #{flag}."])
        end
      end
    end
  end
end

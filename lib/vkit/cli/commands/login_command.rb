require "io/console"
require_relative "../secret_input"
require_relative "../../core/auth_client"
require_relative "../../core/credential_store"
require "base64"
require "json"

module Vkit
  module CLI
    module Commands
      class LoginCommand < BaseCommand
        def requires_auth?
          false
        end

        def initialize(endpoint: nil, email: nil, password_prompt: false)
          @endpoint = endpoint
          @email = email
          @password_prompt = password_prompt
        end

        def call
          endpoint =
            @endpoint ||
            ENV["VKIT_ENDPOINT"] ||
            credential_store.stored_payload&.dig("endpoint") ||
            (json? ? endpoint_needed! : prompt("VaultKit Control Plane URL"))
          client = Vkit::Core::AuthClient.new(base_url: endpoint)

          discovery = client.discover
          auth = discovery["preferred"]

          result =
            case auth
            when "oidc"
              oidc_flow(client)
            when "password"
              password_flow(client)
            when "token"
              token_flow(client)
            else
              raise "Unsupported auth mode: #{auth}"
            end

          store = Vkit::Core::CredentialStore.new
          store.save(
            endpoint: endpoint,
            token: result[:token],
            user: result[:user]
          )

          Vkit::CLI::Output.register_secret(result[:token])
          puts "✅ Logged in as #{result[:user]['email']}"
          respond(
            { "email" => result[:user]["email"], "role" => result[:user]["role"],
              "organization" => result[:user]["organization_slug"], "endpoint" => endpoint, "auth" => auth },
            ["vkit init --format json", "vkit datasource add --id <id> --engine <engine> --username <user> " \
                                        "--config '<json>' --region <region> --environment <env> --password-prompt"]
          )
        rescue => e
          raise if json?

          puts "❌ Login failed: #{e.message}"
          exit 1
        end

        private

        def oidc_flow(client)
          start = client.start_cli_login
          poll_token = start["poll_token"]
          login_url  = start["login_url"]
        
          open_browser(login_url)
          puts "⏳ Waiting for authentication to complete..."
        
          loop do
            res = client.poll_cli_login(poll_token)
        
            case res.code.to_i
            when 204
              sleep 2
            when 200
              body = JSON.parse(res.body)
              return {
                token: body["token"],
                user: body["user"]
              }
            when 403
              # The browser sign-in was rejected (e.g. not invited, email not
              # verified); the control plane returns the reason.
              raise login_rejection_message(res)
            when 410
              raise "Login session expired"
            when 404
              raise "Invalid login session"
            else
              raise "Unexpected response: #{res.code}"
            end
          end
        end        

        def login_rejection_message(res)
          body = JSON.parse(res.body.to_s)
          body["message"] || body["error"] || "Sign-in was rejected"
        rescue JSON::ParserError
          "Sign-in was rejected"
        end

        def endpoint_needed!
          needs_input!("endpoint_required", "No control plane URL to log in to.",
                       ["Ask the person for their VaultKit control plane URL and rerun with --endpoint <url>."])
        end

        # Under --format json the password never goes through stdin (an
        # agent's pipe): only the terminal, and only when asked for.
        def password_flow(client)
          if json?
            needs_input!("email_required", "Password login needs an email.", ["Rerun with --email <address>."]) unless @email
            secret_needed! unless @password_prompt
          end

          email = @email || prompt("Email")
          password = @password_prompt ? Vkit::CLI::SecretInput.from_tty("Password") : prompt_password("Password")
          Vkit::CLI::Output.register_secret(password)

          res = client.password_login(email: email, password: password)

          {
            token: res[:token],
            user: res[:user]
          }
        end

        def token_flow(client)
          token = ENV["VAULTKIT_TOKEN"]
          token ||= Vkit::CLI::SecretInput.from_tty("API Token") if @password_prompt
          secret_needed! if token.nil? && json?
          token ||= prompt_password("API Token")
          Vkit::CLI::Output.register_secret(token)
          user = client.whoami(token)

          {
            token: token,
            user: user
          }
        end

        def secret_needed!
          needs_input!("secret_required", "Logging in needs a secret the person has to type.",
                       ["Ask the person to run `vkit login --password-prompt` in their own terminal " \
                        "and type it there, then rerun your command."])
        end

        def prompt(label)
          print "#{label}: "
          STDIN.gets.strip
        end

        def prompt_password(label)
          print "#{label}: "
          STDIN.noecho(&:gets).to_s.strip.tap { puts }
        end

        def open_browser(url)
          os = RbConfig::CONFIG["host_os"]

          if os =~ /darwin/
            system("open", url)
          elsif os =~ /linux/
            system("xdg-open", url)
          elsif os =~ /mswin|mingw|cygwin/
            system("start", url)
          else
            puts "Open this URL in your browser:\n#{url}"
          end
        end
      end
    end
  end
end

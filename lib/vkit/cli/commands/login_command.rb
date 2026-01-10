require "io/console"
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

        def initialize(endpoint: nil, email: nil)
          @endpoint = endpoint
          @email = email
        end

        def call
          endpoint =
            @endpoint ||
            ENV["VKIT_ENDPOINT"] ||
            credential_store.endpoint ||
            prompt("VaultKit Control Plane URL")
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

          puts "✅ Logged in as #{result[:user]['email']}"
        rescue => e
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
            when 410
              raise "Login session expired"
            when 404
              raise "Invalid login session"
            else
              raise "Unexpected response: #{res.code}"
            end
          end
        end        

        def password_flow(client)
          email = @email || prompt("Email")
          password = prompt_password("Password")

          res = client.password_login(email: email, password: password)

          {
            token: res[:token],
            user: res[:user]
          }
        end

        def token_flow(client)
          token = ENV["VAULTKIT_TOKEN"] || prompt_password("API Token")
          user = client.whoami(token)

          {
            token: token,
            user: user
          }
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

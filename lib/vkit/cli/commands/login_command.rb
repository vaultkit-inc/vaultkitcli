require "io/console"
require_relative "../../core/auth_client"
require_relative "../../core/credential_store"
require_relative "../../core/audit_logger"
require "base64"
require "json"

module Vkit
  module CLI
    module Commands
      class LoginCommand
        def initialize(server: nil, email: nil)
          @server = server || Vkit::Core::AuthClient::DEFAULT_BASE_URL
          @email  = email
          @audit  = Vkit::Core::AuditLogger.new
        end

        def call
          email = @email || begin
                              print "Email: "
                              STDIN.gets.strip
                            end

          print "Password: "
          password = STDIN.noecho(&:gets).to_s.strip
          puts

          client = Vkit::Core::AuthClient.new(base_url: @server)
          res = client.login(email: email, password: password)

          save_credentials(res[:token], res[:user])

          @audit.log(
            event_type: "auth.login.success",
            actor: email,
            metadata: {
              server: @server,
              role: res[:user]["role"],
              org: res[:user]["organization_id"]
            }
          )

          puts "✅ Logged in as #{res[:user]["email"]} (role: #{res[:user]["role"]})"
        rescue => e
          @audit.log(
            event_type: "auth.login.failure",
            actor: email,
            metadata: { error: e.message }
          )

          puts "❌ Login failed: #{e.message}"
          exit 1
        end

        def call_whoami
          store = Vkit::Core::CredentialStore.new
          token = store.load_token
          user  = store.load_user

          if token.nil? || user.nil?
            puts "Not logged in. Run: vkit login"
            exit 1
          end

          payload = decode_jwt_payload(token)
          exp = payload["exp"] ? Time.at(payload["exp"]).utc : nil

          @audit.log(
            event_type: "auth.whoami",
            actor: user["email"],
            metadata: { token_exp: exp }
          )

          puts "👤 #{user["email"]} (role: #{user["role"]}, org: #{user["organization_id"]})"
          puts "🔒 Token expires: #{exp} (#{time_left(exp)})" if exp
        end

        def call_logout
          store = Vkit::Core::CredentialStore.new
          user  = store.load_user

          @audit.log(
            event_type: "auth.logout",
            actor: user ? user["email"] : nil,
            metadata: {}
          )

          store.clear!
          puts "🧹 Logged out."
        end

        private

        def save_credentials(token, user)
          store = Vkit::Core::CredentialStore.new
          store.save_token(token: token, user: user)
        end

        def decode_jwt_payload(token)
          _header, payload, _sig = token.split(".")
          JSON.parse(Base64.urlsafe_decode64(payload))
        end

        def time_left(exp)
          diff = exp - Time.now
          return "expired" if diff < 0
          "#{(diff / 60).to_i}m"
        end
      end
    end
  end
end

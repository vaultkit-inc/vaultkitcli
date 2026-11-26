require "time"

module Vkit
  module CLI
    module Commands
      class LogoutCommand < BaseCommand
        SETUP_TOKEN_PREFIX = "vkit_setup_".freeze
        # The control plane already ended it: nothing left to revoke.
        SETUP_ALREADY_ENDED = %w[setup_token_expired setup_token_revoked setup_token_invalid].freeze

        # Always the saved login, even when VKIT_ENDPOINT/VKIT_TOKEN are set.
        # A setup session's token is revoked on the control plane first
        # (DELETE /api/setup_sessions/current); whatever that answers, the
        # login is cleared here.
        def call
          saved = credential_store.stored_payload || {}
          token = saved["token"]
          result = { "logged_out" => true }

          if token && setup_token?(saved)
            result.merge!(revoke_setup_session(saved))
          elsif token
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
          respond(result, ["vkit login"])
        end

        private

        def setup_token?(saved)
          saved["setup"] || saved["token"].to_s.start_with?(SETUP_TOKEN_PREFIX)
        end

        def revoke_setup_session(saved)
          Vkit::CLI::Output.register_secret(saved["token"])
          Vkit::Core::AuthClient.new(base_url: saved["endpoint"]).end_setup_session(saved["token"])
          puts "🔒 Setup session ended on the control plane"
          { "setup_session_revoked" => true }
        rescue Vkit::Core::AuthClient::HTTPError => e
          return { "setup_session_revoked" => true, "already_ended" => true } if already_ended?(e)

          revoke_failed(saved, "HTTP #{e.status}")
        rescue StandardError => e
          revoke_failed(saved, e.message)
        end

        def already_ended?(error)
          error.status == 401 && SETUP_ALREADY_ENDED.include?(JSON.parse(error.body.to_s)["code"])
        rescue JSON::ParserError
          false
        end

        def revoke_failed(saved, reason)
          expires_at = saved.dig("setup", "expires_at")
          until_when = expires_at ? "until it expires at #{clock(expires_at)}" : "until it expires"
          warning = "Couldn't end the setup session on the control plane (#{reason}). It's cleared here, but the " \
                    "token stays valid #{until_when}; an admin can revoke it on the console's Agents page."
          warn "⚠️  #{warning}"
          { "setup_session_revoked" => false, "warning" => warning, "expires_at" => expires_at }.compact
        end

        def clock(iso)
          Time.parse(iso.to_s).localtime.strftime("%H:%M")
        rescue ArgumentError
          iso.to_s
        end
      end
    end
  end
end

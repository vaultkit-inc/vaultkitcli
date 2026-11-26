# frozen_string_literal: true

require "time"
require "rbconfig"
require_relative "../../core/auth_client"
require_relative "../../core/credential_store"

module Vkit
  module CLI
    module Commands
      # `vkit login --setup`: a setup session (device authorization, like
      # `gh auth login`) for a coding agent that sets VaultKit up. vkit asks
      # the control plane for one, shows the person a code and a console
      # link, and polls until an admin approves or denies it there. The token
      # it gets acts for that admin, only on setup endpoints, for 30 minutes,
      # and is saved like a normal login, marked as a setup session.
      #
      # In a terminal it's one command that waits. Under --format json it's
      # two, so an agent can show the person the code before it waits:
      #
      #   vkit login --setup --format json        # needs_input (exit 3): user_code, verification_url
      #   vkit login --setup --wait --format json # polls; ok with the login, or an error
      #
      # The requested session is kept between the two (with the saved login),
      # so rerunning the first returns the same code rather than a new one.
      class SetupLoginCommand < BaseCommand
        DEFAULT_INTERVAL = 5
        WAIT_COMMAND = "vkit login --setup --wait --format json"
        APPROVE_FIX = "Ask the person to open the URL, check the code matches, and approve"

        def requires_auth?
          false
        end

        # wait: poll for a session an earlier `vkit login --setup` requested.
        # timeout: stop waiting after this many seconds (still pending is
        # needs_input again); default: until the session expires.
        def initialize(endpoint: nil, wait: false, browser: true, timeout: nil)
          @endpoint = endpoint
          @wait = wait
          @browser = browser
          @timeout = timeout
        end

        def call
          pending = credential_store.pending_setup

          if @wait
            raise not_started unless pending
          else
            pending = nil unless reusable?(pending)
            pending ||= start(resolve_endpoint)
            show(pending)
            approval_needed!(pending, "An admin has to approve this setup session in the console.") if json?
          end

          wait_for_approval(pending)
        end

        private

        def resolve_endpoint
          @endpoint ||
            ENV["VKIT_ENDPOINT"] ||
            credential_store.stored_payload&.dig("endpoint") ||
            (json? ? endpoint_needed! : prompt("VaultKit Control Plane URL"))
        end

        # A requested session that's still worth waiting for: same control
        # plane, not expired. One the person may already be looking at.
        def reusable?(pending)
          return false unless pending
          return false if @endpoint && @endpoint.chomp("/") != pending["endpoint"].to_s.chomp("/")

          !expired?(pending)
        end

        def start(endpoint)
          res = Vkit::Core::AuthClient.new(base_url: endpoint).start_setup_session
          Vkit::CLI::Output.register_secret(res["device_code"])
          pending = {
            "endpoint" => endpoint,
            "device_code" => res["device_code"],
            "user_code" => res["user_code"],
            "verification_url" => res["verification_url"],
            "verification_url_complete" => res["verification_url_complete"] || res["verification_url"],
            "interval" => (res["interval"] || DEFAULT_INTERVAL).to_i,
            "expires_at" => (now + res["expires_in"].to_i).utc.iso8601
          }
          credential_store.save_pending_setup(pending)
          @started = true
          pending
        end

        def show(pending)
          puts "🔐 An admin approves this setup session in the VaultKit console:"
          puts "   1. Open #{pending['verification_url']}"
          puts "   2. Check the code matches: #{pending['user_code']}"
          puts "   3. Approve it (by #{clock(pending['expires_at'])}, when the request expires)"
          puts "   Only approve it if you just started it in your own terminal."
          open_browser(pending["verification_url_complete"]) if @browser && @started
        end

        def wait_for_approval(pending)
          Vkit::CLI::Output.register_secret(pending["device_code"])
          client = Vkit::Core::AuthClient.new(base_url: pending["endpoint"])
          interval = (pending["interval"] || DEFAULT_INTERVAL).to_i
          give_up_at = @timeout ? now + @timeout.to_f : nil
          puts "⏳ Waiting for an admin to approve it..."

          loop do
            expired!(pending) if expired?(pending)
            still_waiting!(pending) if give_up_at && now + interval > give_up_at

            sleep interval
            status, body = client.poll_setup_session(pending["device_code"])
            return finish(pending, body) if status == 200 && body["access_token"]

            case status == 429 ? "rate_limited" : body["error"]
            when "authorization_pending"
              next
            when "slow_down"
              interval = (body["interval"] || interval + 5).to_i
              credential_store.save_pending_setup(pending.merge("interval" => interval))
            when "rate_limited"
              sleep [body["retry_after"].to_i, 1].max
            when "access_denied"
              ended!(pending, "setup_session_denied", body,
                     "Ask the person whether they meant to deny it; to try again, run `vkit login --setup`.")
            when "expired_token"
              expired!(pending)
            when "invalid_grant"
              ended!(pending, "setup_session_invalid", body,
                     "Run `vkit login --setup` to request a new setup session.")
            else
              raise Vkit::CLI::CommandError.new(
                "The control plane answered the setup session poll with HTTP #{status}: " \
                "#{body['error_description'] || body['error']}",
                code: "setup_poll_failed", fix: ["Rerun `#{WAIT_COMMAND}`; if it keeps failing, run `vkit login --setup` again."]
              )
            end
          end
        end

        def finish(pending, body)
          token = body["access_token"]
          Vkit::CLI::Output.register_secret(token)
          user = body["user"] || {}
          org = body.dig("organization", "slug") || user["organization_slug"]
          expires_at = body["expires_at"] || (now + body["expires_in"].to_i).utc.iso8601

          previous = credential_store.stored_payload || {}
          replaced = previous["token"] && !previous["setup"] ? previous.dig("user", "email") : nil

          credential_store.save(
            endpoint: pending["endpoint"],
            token: token,
            user: user,
            setup: { "expires_at" => expires_at, "organization" => org }
          )

          puts "✅ Setup session approved by #{user['email']} for #{org}; it works until #{clock(expires_at)}."
          puts "   It can only connect datasources, scan schemas and deploy policies. " \
               "Run `vkit logout` when setup is done to end it."
          if replaced
            puts "   It replaced your saved login (#{replaced}); run `vkit login` afterwards to sign in as yourself again."
          end

          result = { "setup_session" => true, "email" => user["email"], "role" => user["role"],
                     "organization" => org, "endpoint" => pending["endpoint"], "auth" => "setup",
                     "expires_at" => expires_at, "allowed_endpoints" => Array(body["allowed_endpoints"]) }
          result["replaced_login"] = replaced if replaced
          respond(result, ["vkit whoami --format json", "vkit init --format json"])
        end

        def approval_needed!(pending, message)
          needs_input!(
            "setup_approval_required", message,
            [APPROVE_FIX, "then run `#{WAIT_COMMAND}` to wait for it"],
            next_steps: [WAIT_COMMAND],
            result: {
              "user_code" => pending["user_code"],
              "verification_url" => pending["verification_url"],
              "verification_url_complete" => pending["verification_url_complete"],
              "expires_at" => pending["expires_at"],
              "endpoint" => pending["endpoint"]
            }
          )
        end

        # --timeout passed with no answer yet.
        def still_waiting!(pending)
          approval_needed!(pending, "Still waiting for an admin to approve the setup session.") if json?

          raise Vkit::CLI::CommandError.new(
            "Still waiting for an admin to approve the setup session (code #{pending['user_code']}).",
            code: "setup_approval_required", fix: ["#{APPROVE_FIX}, then run `vkit login --setup --wait`."]
          )
        end

        def expired!(pending)
          credential_store.clear_pending_setup!
          raise Vkit::CLI::CommandError.new(
            "The setup session request expired before an admin approved it.",
            code: "setup_session_expired",
            fix: ["Run `vkit login --setup` for a new code. #{APPROVE_FIX} within 10 minutes."],
            next_steps: ["vkit login --setup --format json"]
          )
        end

        def ended!(pending, code, body, fix)
          credential_store.clear_pending_setup!
          raise Vkit::CLI::CommandError.new(
            body["error_description"] || body["error"].to_s, code: code, fix: [fix],
            next_steps: ["vkit login --setup --format json"]
          )
        end

        def not_started
          Vkit::CLI::CommandError.new(
            "There's no setup session waiting for approval.",
            code: "setup_session_not_started",
            fix: ["Run `vkit login --setup --format json` first; it returns the code to show the person."],
            next_steps: ["vkit login --setup --format json"]
          )
        end

        def endpoint_needed!
          needs_input!("endpoint_required", "No control plane URL to request a setup session from.",
                       ["Ask the person for their VaultKit control plane URL and rerun with --endpoint <url>."])
        end

        def expired?(pending)
          Time.parse(pending["expires_at"].to_s) <= now
        rescue ArgumentError
          true
        end

        def clock(iso)
          Time.parse(iso.to_s).localtime.strftime("%H:%M")
        rescue ArgumentError
          iso.to_s
        end

        def now
          Time.now
        end

        def prompt(label)
          print "#{label}: "
          $stdin.gets.to_s.strip
        end

        # Best effort: the code and link are printed either way.
        def open_browser(url)
          return if url.to_s.empty?

          cmd =
            case RbConfig::CONFIG["host_os"]
            when /darwin/ then ["open", url]
            when /linux|bsd/ then ["xdg-open", url]
            when /mswin|mingw|cygwin/ then ["cmd", "/c", "start", "", url]
            end
          return unless cmd

          pid = Process.spawn(*cmd, out: File::NULL, err: File::NULL)
          Process.detach(pid)
        rescue StandardError
          nil
        end
      end
    end
  end
end

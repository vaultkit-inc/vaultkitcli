# frozen_string_literal: true

require "socket"
require "net/http"
require "openssl"
require_relative "errors"
require_relative "../core/auth_client"
require_relative "api/client"

module Vkit
  module CLI
    # Turns an exception into the envelope's error: a stable code, the
    # message, and one sentence saying what to do. Only codes the CLI or the
    # control plane can actually tell apart are used.
    module ErrorMap
      LOGIN_FIX = "Ask the person to run `vkit login` in their own terminal (it opens a browser or asks for " \
                  "their password), or set VKIT_ENDPOINT and VKIT_TOKEN, then rerun this command."

      SETUP_EXPIRED_FIX = "Setup sessions last 30 minutes. Run `vkit login --setup` for a new one (with --format json " \
                          "it returns a code; ask the person to open the URL, check the code matches, and approve), " \
                          "then rerun this command."
      SETUP_SCOPE_FIX = "A setup session can't do this; an admin must. Ask the person to sign in as themselves with " \
                        "`vkit login` and run it, or, if the organization is already set up and they want this " \
                        "session to change it, approve a new one with \"Allow this session to replace existing " \
                        "policies and datasources\" ticked."

      # The control plane's codes for a setup token it refuses (401), by
      # what vkit calls them.
      SETUP_TOKEN_ERRORS = {
        "setup_token_expired" => ["setup_session_expired", "The setup session has expired.", SETUP_EXPIRED_FIX],
        "setup_token_revoked" => ["setup_session_revoked", "The setup session was revoked (in the console, or by " \
                                  "`vkit logout`).",
                                  "Ask the person whether to start another; if so, run `vkit login --setup`, then " \
                                  "rerun this command."],
        "setup_token_invalid" => ["setup_session_invalid", "The control plane doesn't know this setup token.",
                                  "Run `vkit login --setup` for a new setup session, then rerun this command."],
        "setup_approver_not_admin" => ["setup_approver_not_admin",
                                       "The admin who approved this setup session is no longer an admin.",
                                       "Ask an admin of the organization to approve a new setup session " \
                                       "(`vkit login --setup`), then rerun this command."]
      }.freeze

      # 409s the control plane answers with a code.
      CONFLICT_FIXES = {
        "datasource_exists" => "A datasource with this id already exists with different settings, and it can't " \
                               "be changed from vkit. Add it under a new id, or rerun with the settings it already " \
                               "has (`vkit datasource get <id>`).",
        "bundle_version_exists" => "This bundle version was already uploaded with other contents, and a version " \
                                   "can only be uploaded once. Commit your policy changes and rebuild with " \
                                   "`vkit policy bundle` (the version is the commit), or name a new one with " \
                                   "--version <label>.",
        "bundle_checksum_exists" => "These exact policies were already uploaded under another version (the " \
                                    "message names it), so there's nothing new to deploy. If that version isn't " \
                                    "active, an admin can activate it in the console; otherwise change the " \
                                    "policies and rebuild."
      }.freeze

      UNREACHABLE = [
        Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ECONNRESET, Errno::ETIMEDOUT,
        Errno::EADDRNOTAVAIL, SocketError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError
      ].freeze

      USER_TOKEN_REASONS = { "Signature has expired" => "token_expired", "revoked token" => "token_revoked" }.freeze

      # What the control plane passes on from funl when it can't reach or
      # log in to a datasource (only vkit scan connects; datasource add
      # doesn't). funl gives a refused connection and a failed login the same
      # code, datasource_unavailable, so only its wording tells them apart,
      # and a failed login looks like any other failed connection.
      DATASOURCE_ERRORS = [
        [/datasource_unavailable\): Couldn't reach the datasource/, "datasource_unreachable",
         "Check the datasource's host and port in its config and that the database is running and reachable " \
         "from VaultKit, then rerun the scan."],
        [/datasource_unavailable\)/, "datasource_connection_failed",
         "Check the datasource's username and password (and that the database accepts connections from " \
         "VaultKit); a wrong password looks the same as other connection failures."],
        [/\(permission_denied\)/, "datasource_permission_denied",
         "Grant the datasource's database role read access to the tables it should scan, then rerun."],
        [/\(query_failed\)/, "datasource_query_failed",
         "The datasource rejected the scan's query; check its config (host, port, database) and that the " \
         "role can read the schema, then rerun."],
        [/\((datasource_busy|query_timeout)\)/, "datasource_busy",
         "The datasource is overloaded or slow; wait a little and rerun."],
        [/Failed to open TCP connection|Funl rejected|Funl error/, "query_runtime_unavailable",
         "VaultKit's query runtime (funl) failed or couldn't be reached; ask whoever runs the control plane " \
         "to check it, then rerun."]
      ].freeze

      module_function

      def datasource_error(message)
        DATASOURCE_ERRORS.each do |pattern, code, fix|
          return error(code, message, fix) if message.match?(pattern)
        end
        nil
      end

      def map(e)
        case e
        when NeedsInput
          command_error(e, "needs_input")
        when CommandError
          command_error(e, "error")
        when API::APIError
          api_error(e)
        when Vkit::Core::AuthClient::HTTPError
          api_error(auth_http_error(e))
        when *UNREACHABLE
          unreachable(e)
        when Thor::Error
          error("invalid_arguments", e.message,
                "Fix the arguments as the message says; `vkit help <command>` lists a command's options.")
        when Interrupt
          error("interrupted", "Interrupted", "Rerun the command.").merge(exit_code: 130)
        else
          mapped_by_class(e) || error("command_failed", e.message.to_s.strip,
                                      "Read the message, fix what it names, and rerun the command.")
        end
      end

      # The fix to print under a human-mode error, for the errors whose fix
      # matters more than the message (setup sessions, conflicts); nil for
      # the rest, which print as they always have.
      def human_fix(e)
        code = e.respond_to?(:code) ? e.code.to_s : ""
        mapped = map(e) if e.is_a?(API::APIError) || e.is_a?(CommandError)
        return nil unless mapped

        mapped_code = mapped[:code].to_s
        relevant = [code, mapped_code].any? { |c| c.start_with?("setup_") } || CONFLICT_FIXES.key?(mapped_code)
        relevant ? mapped[:fix] : nil
      end

      def error(code, message, fix, **extra)
        { status: "error", code: code, message: message, fix: fix }.merge(extra)
      end

      # A CommandError's fix is lines (often commands); the envelope's is one
      # sentence, so they're joined.
      def command_error(e, status)
        fix = e.fix.empty? ? "Read the message, fix what it names, and rerun the command." : e.fix.join("; ")
        out = { status: status, code: e.code, message: e.message, fix: fix, next_steps: e.next_steps }
        out[:exit_code] = e.exit_code if e.exit_code
        out[:result] = e.result if e.result
        out
      end

      def auth_http_error(e)
        body = begin
          JSON.parse(e.body.to_s)
        rescue JSON::ParserError
          e.body.to_s
        end
        API::APIError.from_body(e.status, body)
      end

      def unreachable(e)
        error("control_plane_unreachable", "Couldn't reach the VaultKit control plane: #{e.message}",
              "Check that the control plane is running and that the endpoint is right " \
              "(`vkit whoami`, or VKIT_ENDPOINT), then rerun the command.")
      end

      # 401s carry the control plane's reason in code (token_expired,
      # token_revoked). Everything else keeps the server's code when it sends
      # one, so nothing is lost.
      def api_error(e)
        extra = e.request_id ? { request_id: e.request_id } : {}
        message = e.error.is_a?(String) ? e.error : e.error.to_json

        if (ds = datasource_error(message))
          return ds.merge(extra)
        end

        if (setup = SETUP_TOKEN_ERRORS[e.code])
          code, text, fix = setup
          return error(code, "#{text} (#{message})", fix, **extra)
        end

        case e.status
        when 401
          # Agent tokens say why in code; a person's login (a Devise JWT)
          # only in the message.
          reason = e.code || USER_TOKEN_REASONS.find { |text, _| message.include?(text) }&.last
          case reason
          when "token_expired"
            error("session_expired", "Your VaultKit session has expired.",
                  "Login sessions last an hour. #{LOGIN_FIX}", **extra)
          when "token_revoked"
            error("token_revoked", "This VaultKit token has been revoked.",
                  "Use a token that is still valid. #{LOGIN_FIX}", **extra)
          else
            error("not_authenticated", "The control plane didn't accept your credentials (#{message}).",
                  LOGIN_FIX, **extra)
          end
        when 403
          return error("setup_scope_forbidden", message, SETUP_SCOPE_FIX, **extra) if e.code == "setup_scope_forbidden"

          error(e.code || "forbidden", message,
                "Your role isn't allowed to do this; ask an admin of the organization to do it or to change your role.",
                **extra)
        when 409
          if (fix = CONFLICT_FIXES[e.code])
            return error(e.code, message, fix, **extra)
          end

          error(e.code || "api_error", message,
                "Read the control plane's message and fix what it names, then rerun the command.",
                **extra.merge(http_status: e.status))
        when 404
          error(e.code || "not_found", message, "Check the name or ID you passed; list what exists first.", **extra)
        else
          error(e.code || "api_error", message,
                "Read the control plane's message and fix what it names, then rerun the command.",
                **extra.merge(http_status: e.status))
        end
      end

      def mapped_by_class(e)
        manager = Vkit::CLI::PolicyPack::Manager if defined?(Vkit::CLI::PolicyPack::Manager)
        if manager && e.is_a?(manager::PackNotFound)
          packs = manager.new.available_packs
          return error("unknown_pack", e.message,
                       "Use one of the packs this CLI ships: #{packs.join(', ')} (`vkit policy pack list`).",
                       result: { "available_packs" => packs })
        end
        if manager && e.is_a?(manager::DependencyMissing)
          return error("pack_dependency_missing", e.message, "Add the packs it needs first, then rerun this command.")
        end
        if defined?(Vkit::Policy::ValidationError) && e.is_a?(Vkit::Policy::ValidationError)
          return error("policy_invalid", e.message, "Fix the policies or registry the message names, then rerun.")
        end
        if e.message.to_s.start_with?("Not a VaultKit project", "Directory does not exist")
          return error("not_a_project", e.message, "Run `vkit init` first, or pass --dir <project folder>.")
        end
        if e.is_a?(JSON::ParserError)
          return error("invalid_json", e.message, "Pass valid JSON.")
        end

        nil
      end
    end
  end
end

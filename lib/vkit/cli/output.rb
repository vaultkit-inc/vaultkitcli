# frozen_string_literal: true

require "json"
require "stringio"
require_relative "errors"

module Vkit
  module CLI
    # --format json: every command prints exactly one object to stdout,
    #
    #   { "status": "ok" | "error" | "needs_input", "result": {...},
    #     "next": ["<command to run next>", ...],
    #     "error": { "code", "message", "fix" } }
    #
    # and everything else (progress, warnings, the human output) goes to
    # stderr. Commands record their result with Output.respond; errors are
    # raised and turned into the envelope here, by ErrorMap.
    module Output
      EXIT_OK = 0
      EXIT_ERROR = 1
      # The command needs something only the person can give (a secret, a
      # confirmation). Distinct from errors so an agent can tell them apart.
      EXIT_NEEDS_INPUT = 3

      REDACTED = "[REDACTED]"

      class << self
        # The real stdout while a JSON command runs ($stdout is stderr then).
        attr_reader :stdout

        def json?
          !!@json
        end

        # Whether argv asks for JSON, before Thor has parsed it, so even an
        # unknown option or a missing argument comes back as an envelope.
        def json_requested?(argv)
          argv.each_with_index.any? do |arg, i|
            break false if arg == "--"

            arg == "--format=json" || (arg == "--format" && argv[i + 1] == "json")
          end
        end

        # Records the command's result. exit_code is for the few commands
        # whose exit codes scripts already rely on (vkit registry diff).
        def respond(result: {}, next_steps: [], exit_code: EXIT_OK)
          @response = { result: result, next_steps: Array(next_steps), exit_code: exit_code }
          result
        end

        # The command wrote its own stream to stdout (vkit approvals:watch),
        # so there's no envelope to add after it.
        def streamed!
          @streamed = true
        end

        # Values that must never appear in the envelope, however they got
        # into a message: passwords, tokens.
        def register_secret(value)
          value = value.to_s
          return if value.length < 4

          (@secrets ||= []) << value unless (@secrets ||= []).include?(value)
        end

        # An exit code for an error, overriding the default of 1, for
        # commands that already document theirs.
        attr_writer :error_exit_code

        # Runs the block (the command) in JSON mode, prints the envelope and
        # exits with its code. Never returns.
        def run_json(out: $stdout)
          envelope, code = capture_json(out: out) { yield }
          out.puts(JSON.generate(envelope)) if envelope
          out.flush
          exit code
        end

        # The envelope and exit code, without printing or exiting (for tests
        # and run_json).
        def capture_json(out: $stdout)
          reset!
          @json = true
          @stdout = out
          saved = $stdout
          $stdout = $stderr

          envelope, code =
            begin
              yield
              success
            rescue SystemExit => e
              exited(e)
            rescue Exception => e # rubocop:disable Lint/RescueException
              raise if e.is_a?(NoMemoryError) || e.is_a?(SignalException) && !e.is_a?(Interrupt)

              failure(e)
            end

          [@streamed && code.zero? ? nil : redact(envelope), code]
        ensure
          $stdout = saved
          @json = false
        end

        def reset!
          @response = nil
          @streamed = false
          @secrets = []
          @error_exit_code = nil
        end

        private

        def success
          r = @response || { result: {}, next_steps: [], exit_code: EXIT_OK }
          [envelope("ok", r[:result], r[:next_steps]), r[:exit_code]]
        end

        # A command that exits on its own: a recorded result means it was
        # done; otherwise a non-zero exit is an error it already printed (to
        # stderr, now).
        def exited(e)
          return success if @response
          return [envelope("ok", {}, []), EXIT_OK] if e.success?

          error = { "code" => "command_failed", "message" => "The command failed; see stderr for details.",
                    "fix" => "Read the message on stderr and fix what it names, then rerun the command." }
          [envelope("error", {}, [], error), e.status]
        end

        def failure(e)
          mapped = ErrorMap.map(e)
          status = mapped.delete(:status)
          code = status == "needs_input" ? EXIT_NEEDS_INPUT : (@error_exit_code || mapped.delete(:exit_code) || EXIT_ERROR)
          mapped.delete(:exit_code)
          next_steps = mapped.delete(:next_steps) || []
          result = mapped.delete(:result) || {}
          [envelope(status, result, next_steps, mapped.transform_keys(&:to_s)), code]
        end

        def envelope(status, result, next_steps, error = nil)
          env = { "status" => status, "result" => result || {}, "next" => next_steps }
          env["error"] = error if error
          env
        end

        def redact(envelope)
          return envelope if @secrets.empty?

          json = JSON.generate(envelope)
          @secrets.sort_by { |s| -s.length }.each do |s|
            json = json.gsub(JSON.generate(s)[1..-2], REDACTED)
          end
          JSON.parse(json)
        end
      end
    end
  end
end

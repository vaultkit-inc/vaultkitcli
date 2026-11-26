module Vkit
  module CLI
    class Error < StandardError; end
    class ConfigError < Error; end

    # An error with a stable code that scripts and agents can match on, and
    # the commands that fix it.
    class CommandError < Error
      attr_reader :code, :fix, :next_steps, :exit_code, :result

      # result: what the envelope's result carries alongside the error (for
      # needs_input, what the person has to be shown).
      def initialize(message, code:, fix: [], next_steps: [], exit_code: nil, result: nil)
        super(message)
        @code = code
        @fix = Array(fix)
        @next_steps = Array(next_steps)
        @exit_code = exit_code
        @result = result
      end

      def to_h
        { "status" => "error", "code" => code, "error" => message, "fix" => fix }
      end

      def render
        lines = ["❌ #{message}", "   Code: #{code}"]
        lines += ["   Fix:", *fix.map { |f| "     #{f}" }] unless fix.empty?
        lines.join("\n")
      end
    end

    # The command can't go on without something only the person can give: a
    # secret, a confirmation, a choice. Under --format json it's reported as
    # status "needs_input" (exit 3) instead of waiting on a prompt.
    class NeedsInput < CommandError; end
  end
end

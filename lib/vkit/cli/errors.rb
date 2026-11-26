module Vkit
  module CLI
    class Error < StandardError; end
    class ConfigError < Error; end

    # An error with a stable code that scripts and agents can match on, and
    # the commands that fix it.
    class CommandError < Error
      attr_reader :code, :fix

      def initialize(message, code:, fix: [])
        super(message)
        @code = code
        @fix = Array(fix)
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
  end
end

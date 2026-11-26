# frozen_string_literal: true

require "io/console"
require_relative "errors"

module Vkit
  module CLI
    # Secrets come from the person's terminal or the environment, never from
    # a command-line argument (shell history, agent transcripts) or stdin (an
    # agent's pipe).
    module SecretInput
      TTY = "/dev/tty"

      module_function

      # Reads one line from the controlling terminal with echo off. The prompt
      # goes to the terminal too, so nothing touches stdout or stderr.
      def from_tty(label, tty_path: TTY)
        File.open(tty_path, "r+") do |tty|
          tty.print "#{label}: "
          tty.flush
          value = tty.respond_to?(:noecho) && tty.tty? ? tty.noecho(&:gets) : tty.gets
          tty.puts
          value.to_s.chomp
        end
      rescue Errno::ENXIO, Errno::ENOENT, Errno::EACCES, Errno::ENOTTY, Errno::EIO
        raise Vkit::CLI::NeedsInput.new(
          "There's no terminal to type the secret into.",
          code: "secret_required",
          fix: ["Ask the person to run this command with --password-prompt in their own terminal."]
        )
      end

      # The value of an environment variable, by name. The name, not the
      # value, is what errors mention.
      def from_env(name)
        value = ENV[name.to_s]
        if value.nil? || value.empty?
          raise Vkit::CLI::CommandError.new(
            "Environment variable #{name} is not set (or is empty).",
            code: "secret_env_missing",
            fix: ["Set #{name} in the environment vkit runs in, or use --password-prompt."]
          )
        end

        value
      end
    end
  end
end

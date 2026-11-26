require "thor"
require_relative "version"

require_relative "cli/errors"
require_relative "cli/output"
require_relative "cli/error_map"
require_relative "cli/commands"
require_relative "cli/base_cli"

module Vkit
  module CLI
    def self.start(argv = ARGV)
      json = Output.json_requested?(argv)

      if %w[--version -v].include?(argv.first)
        Output.run_json { Output.respond(result: { "version" => Vkit::VERSION }) } if json
        puts "vkit #{Vkit::VERSION}"
        exit 0
      end

      return BaseCLI.start(argv) unless json

      # debug: Thor raises its own errors (an unknown option, a missing
      # argument) instead of printing them, so they come back as an envelope.
      Output.run_json { BaseCLI.start(argv, debug: true) }
    end
  end
end

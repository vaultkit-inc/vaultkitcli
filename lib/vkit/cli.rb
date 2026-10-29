require "thor"
require_relative "version"

require_relative "cli/commands"
require_relative "cli/base_cli"

module Vkit
  module CLI
    def self.start(argv = ARGV)
      if %w[--version -v].include?(argv.first)
        puts "vkit #{Vkit::VERSION}"
        exit 0
      end

      BaseCLI.start(argv)
    end
  end
end
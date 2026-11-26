# frozen_string_literal: true

require "json"
require "stringio"
require_relative "../../lib/vkit/cli"

# Runs a block as `--format json` would and returns [envelope, exit code,
# stderr], so tests check exactly what an agent would see.
module EnvelopeHelper
  def run_json
    out = StringIO.new
    err = StringIO.new
    saved_err = $stderr
    $stderr = err
    envelope, code = Vkit::CLI::Output.capture_json(out: out) { yield }
    [envelope, code, err.string]
  ensure
    $stderr = saved_err
  end

  # The whole CLI, from argv, as bin/vkit runs it.
  def run_cli(*argv)
    out = StringIO.new
    err = StringIO.new
    saved_err = $stderr
    $stderr = err
    code = 0
    begin
      envelope, code = Vkit::CLI::Output.capture_json(out: out) { Vkit::CLI::BaseCLI.start(argv, debug: true) }
      out.puts(JSON.generate(envelope)) if envelope
    end
    [out.string, code, err.string]
  ensure
    $stderr = saved_err
  end
end

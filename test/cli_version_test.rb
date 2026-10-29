# frozen_string_literal: true

# Run with: ruby -Ilib test/cli_version_test.rb
require "minitest/autorun"
require_relative "../lib/vkit/cli"

class CliVersionFlagTest < Minitest::Test
  # Runs Vkit::CLI.start, recording the argv that reaches Thor instead of
  # running a command. Returns [stdout, argv passed to Thor or :exited].
  def start(argv)
    received = nil
    thor = Vkit::CLI::BaseCLI.singleton_class
    thor.alias_method(:original_start, :start)
    thor.define_method(:start) { |args = ARGV, *| received = args }

    out, = capture_io do
      Vkit::CLI.start(argv)
    rescue SystemExit
      received = :exited
    end
    [out, received]
  ensure
    thor.alias_method(:start, :original_start)
    thor.remove_method(:original_start)
  end

  def test_version_flag_prints_the_version
    %w[--version -v].each do |flag|
      out, received = start([flag])

      assert_equal "vkit #{Vkit::VERSION}\n", out
      assert_equal :exited, received
    end
  end

  def test_version_option_of_a_subcommand_is_passed_through
    argv = %w[policy bundle --version 2026.10.1]

    out, received = start(argv)

    assert_equal "", out
    assert_equal argv, received
  end

  def test_short_v_after_a_command_is_passed_through
    argv = %w[policy bundle -v]

    _out, received = start(argv)

    assert_equal argv, received
  end
end

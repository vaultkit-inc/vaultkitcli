# frozen_string_literal: true

# Run with: ruby -Ilib test/login_command_test.rb
require "minitest/autorun"
require "json"
require_relative "../lib/vkit/cli/commands/base_command"
require_relative "../lib/vkit/cli/commands/login_command"

class LoginCommandOidcPollTest < Minitest::Test
  Response = Struct.new(:code, :body)

  # Serves a fixed sequence of poll responses.
  class FakeClient
    attr_reader :polls

    def initialize(*responses)
      @responses = responses
      @polls = 0
    end

    def start_cli_login
      { "poll_token" => "poll-1", "login_url" => "http://cp.test/auth/oidc/cli/start" }
    end

    def poll_cli_login(_token)
      @polls += 1
      @responses.shift
    end
  end

  def command
    cmd = Vkit::CLI::Commands::LoginCommand.new(endpoint: "http://cp.test")
    cmd.define_singleton_method(:open_browser) { |_url| nil }
    cmd.define_singleton_method(:sleep) { |_seconds| nil }
    cmd.define_singleton_method(:puts) { |*_args| nil }
    cmd
  end

  def oidc_flow(client)
    command.send(:oidc_flow, client)
  end

  def test_shows_the_rejection_reason_and_stops_polling
    client = FakeClient.new(
      Response.new("204", ""),
      Response.new("403", JSON.dump(error: "not_invited", message: "pat@partner.test is not a member of Acme."))
    )

    error = assert_raises(RuntimeError) { oidc_flow(client) }

    assert_equal "pat@partner.test is not a member of Acme.", error.message
    assert_equal 2, client.polls
  end

  def test_falls_back_to_the_error_code_or_a_generic_message
    assert_equal "email_unverified",
                 assert_raises(RuntimeError) { oidc_flow(FakeClient.new(Response.new("403", JSON.dump(error: "email_unverified")))) }.message
    assert_equal "Sign-in was rejected",
                 assert_raises(RuntimeError) { oidc_flow(FakeClient.new(Response.new("403", "Forbidden"))) }.message
  end

  def test_returns_the_token_on_success
    client = FakeClient.new(
      Response.new("204", ""),
      Response.new("200", JSON.dump(token: "tok", user: { "email" => "a@acme.test" }))
    )

    assert_equal({ token: "tok", user: { "email" => "a@acme.test" } }, oidc_flow(client))
  end

  def test_still_reports_expired_sessions
    error = assert_raises(RuntimeError) { oidc_flow(FakeClient.new(Response.new("410", ""))) }

    assert_equal "Login session expired", error.message
  end
end

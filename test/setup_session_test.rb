# frozen_string_literal: true

# Run with: ruby -Ilib test/setup_session_test.rb
#
# `vkit login --setup` (setup sessions, vaultkit#126) with the control plane
# faked: the request, the code shown to the person, polling (slow_down,
# denied, expired), the token saved as a setup session and never printed,
# logout revoking it, and the errors a setup token gets back.
require "minitest/autorun"
require "json"
require "tmpdir"
require "socket"
require_relative "support/envelope"

module SetupTestBackend
  class << self
    attr_accessor :store, :clock, :sleeps, :opened
  end

  def credential_store
    SetupTestBackend.store || super
  end
end
Vkit::CLI::Commands::BaseCommand.prepend(SetupTestBackend)

# A clock that moves only when vkit sleeps, so polling runs instantly.
module SetupTestClock
  def now
    SetupTestBackend.clock || super
  end

  def sleep(seconds)
    return super unless SetupTestBackend.clock

    SetupTestBackend.sleeps << seconds
    SetupTestBackend.clock += seconds
  end

  def open_browser(url)
    SetupTestBackend.opened << url
  end
end
Vkit::CLI::Commands::SetupLoginCommand.prepend(SetupTestClock)

# The control plane's setup-session endpoints: a queue of poll answers.
class FakeSetupAuth
  attr_reader :starts, :polls, :ended

  def initialize(polls: [], end_result: { "status" => "revoked" })
    @poll_answers = polls
    @starts = 0
    @polls = []
    @ended = []
    @end_result = end_result
  end

  def start_setup_session
    @starts += 1
    { "device_code" => "dev-code-secret-#{@starts}", "user_code" => "BCDF-123#{@starts}",
      "verification_url" => "http://console.test/setup/approve",
      "verification_url_complete" => "http://console.test/setup/approve?code=BCDF-123#{@starts}",
      "interval" => 5, "expires_in" => 600 }
  end

  def poll_setup_session(device_code)
    @polls << device_code
    @poll_answers.shift || raise("no more poll answers")
  end

  def end_setup_session(token)
    @ended << token
    raise @end_result if @end_result.is_a?(Exception)

    @end_result
  end

  def logout(_token)
    @ended << :user_logout
  end
end

module SetupTestHelpers
  include EnvelopeHelper

  TOKEN = "vkit_setup_live_token_abcdef123456"
  APPROVED = [200, { "access_token" => TOKEN, "token_type" => "bearer", "scope" => "setup", "expires_in" => 1800,
                     "expires_at" => "2026-11-25T12:30:00Z",
                     "organization" => { "slug" => "fresh", "name" => "Fresh" },
                     "user" => { "email" => "admin@fresh.test", "role" => "admin", "organization_slug" => "fresh" },
                     "allowed_endpoints" => ["GET  /auth/whoami"] }].freeze
  PENDING = [400, { "error" => "authorization_pending" }].freeze

  def setup
    @dir = Dir.mktmpdir
    @saved_env = ENV.to_h
    %w[VKIT_ENDPOINT VKIT_TOKEN].each { |k| ENV.delete(k) }
    store = Vkit::Core::CredentialStore.new
    store.instance_variable_set(:@os, "plan9") # no keychain: the file
    store.instance_variable_set(:@fallback_path, File.join(@dir, "credentials.json"))
    SetupTestBackend.store = store
    SetupTestBackend.clock = Time.utc(2026, 11, 25, 12, 0, 0)
    SetupTestBackend.sleeps = []
    SetupTestBackend.opened = []
  end

  def teardown
    SetupTestBackend.store = nil
    SetupTestBackend.clock = nil
    ENV.replace(@saved_env)
    FileUtils.rm_rf(@dir)
  end

  def store
    SetupTestBackend.store
  end

  def saved
    JSON.parse(File.read(File.join(@dir, "credentials.json")))
  end

  def with_auth_client(fake)
    original = Vkit::Core::AuthClient.method(:new)
    Vkit::Core::AuthClient.define_singleton_method(:new) { |**_| fake }
    yield
  ensure
    Vkit::Core::AuthClient.define_singleton_method(:new, original)
  end

  def cli(fake, *argv)
    with_auth_client(fake) do
      out, code, err = run_cli(*argv, "--format", "json")
      assert_equal 1, out.lines.length, "stdout must be exactly one JSON object:\n#{out}"
      [JSON.parse(out), code, err, out]
    end
  end

  def refute_secrets(*outputs)
    outputs.each do |o|
      refute_includes o, TOKEN
      refute_includes o, "dev-code-secret"
    end
  end
end

class SetupLoginJsonTest < Minitest::Test
  include SetupTestHelpers

  def start(fake)
    cli(fake, "login", "--setup", "--endpoint", "http://cp.test")
  end

  def test_first_call_is_needs_input_with_the_code_and_the_url
    fake = FakeSetupAuth.new
    envelope, code, err, out = start(fake)

    assert_equal 3, code
    assert_equal "needs_input", envelope["status"]
    assert_equal "setup_approval_required", envelope.dig("error", "code")
    assert envelope.dig("error", "fix").start_with?("Ask the person to open the URL, check the code matches, and approve")
    assert_equal "BCDF-1231", envelope.dig("result", "user_code")
    assert_equal "http://console.test/setup/approve", envelope.dig("result", "verification_url")
    assert_equal ["vkit login --setup --wait --format json"], envelope["next"]
    assert_equal ["http://console.test/setup/approve?code=BCDF-1231"], SetupTestBackend.opened
    assert_empty fake.polls, "the first call doesn't wait"
    assert_equal "dev-code-secret-1", store.pending_setup["device_code"]
    refute_secrets(out, err)
  end

  def test_rerunning_it_returns_the_same_code_without_a_new_session
    fake = FakeSetupAuth.new
    start(fake)
    envelope, code, = start(fake)

    assert_equal 3, code
    assert_equal "BCDF-1231", envelope.dig("result", "user_code")
    assert_equal 1, fake.starts
    assert_equal 1, SetupTestBackend.opened.length, "the browser opens once"
  end

  def test_an_expired_request_is_replaced_by_a_new_one
    fake = FakeSetupAuth.new
    start(fake)
    SetupTestBackend.clock += 601

    envelope, = start(fake)

    assert_equal "BCDF-1232", envelope.dig("result", "user_code")
  end

  def test_wait_polls_respecting_slow_down_and_saves_the_token_as_a_setup_session
    fake = FakeSetupAuth.new(polls: [PENDING, [400, { "error" => "slow_down", "interval" => 10 }], PENDING, APPROVED])
    start(fake)

    envelope, code, err, out = cli(fake, "login", "--setup", "--wait")

    assert_equal 0, code, envelope.inspect
    assert_equal true, envelope.dig("result", "setup_session")
    assert_equal "admin@fresh.test", envelope.dig("result", "email")
    assert_equal "fresh", envelope.dig("result", "organization")
    assert_equal "2026-11-25T12:30:00Z", envelope.dig("result", "expires_at")
    assert_equal [5, 5, 10, 10], SetupTestBackend.sleeps
    assert_equal ["dev-code-secret-1"] * 4, fake.polls

    login = saved
    assert_equal TOKEN, login["token"]
    assert_equal "http://cp.test", login["endpoint"]
    assert_equal({ "expires_at" => "2026-11-25T12:30:00Z", "organization" => "fresh" }, login["setup"])
    refute login.key?("pending_setup")
    refute_secrets(out, err)
  end

  def test_a_denied_session_is_an_error_and_forgotten
    fake = FakeSetupAuth.new(polls: [[400, { "error" => "access_denied", "error_description" => "An admin denied this setup session" }]])
    start(fake)

    envelope, code, = cli(fake, "login", "--setup", "--wait")

    assert_equal 1, code
    assert_equal "setup_session_denied", envelope.dig("error", "code")
    assert_nil store.pending_setup
  end

  def test_an_expired_token_answer_is_setup_session_expired
    fake = FakeSetupAuth.new(polls: [[400, { "error" => "expired_token" }]])
    start(fake)

    envelope, code, = cli(fake, "login", "--setup", "--wait")

    assert_equal 1, code
    assert_equal "setup_session_expired", envelope.dig("error", "code")
    assert_includes envelope.dig("error", "fix"), "vkit login --setup"
  end

  def test_waiting_past_the_request_expiry_stops_without_polling_forever
    fake = FakeSetupAuth.new(polls: Array.new(200) { PENDING })
    start(fake)

    envelope, code, = cli(fake, "login", "--setup", "--wait")

    assert_equal 1, code
    assert_equal "setup_session_expired", envelope.dig("error", "code")
    assert_operator fake.polls.length, :<=, 120
  end

  def test_timeout_while_still_pending_is_needs_input_again
    fake = FakeSetupAuth.new(polls: Array.new(10) { PENDING })
    start(fake)

    envelope, code, = cli(fake, "login", "--setup", "--wait", "--timeout", "12")

    assert_equal 3, code
    assert_equal "BCDF-1231", envelope.dig("result", "user_code")
    assert_equal 2, fake.polls.length
    refute_nil store.pending_setup
  end

  def test_wait_with_nothing_requested
    envelope, code, = cli(FakeSetupAuth.new, "login", "--setup", "--wait")

    assert_equal 1, code
    assert_equal "setup_session_not_started", envelope.dig("error", "code")
  end

  def test_no_endpoint_is_needs_input
    envelope, code, = cli(FakeSetupAuth.new, "login", "--setup")

    assert_equal 3, code
    assert_equal "endpoint_required", envelope.dig("error", "code")
  end

  def test_rate_limited_polls_back_off_and_continue
    fake = FakeSetupAuth.new(polls: [[429, { "error" => "rate_limited", "retry_after" => 20 }], APPROVED])
    start(fake)

    _envelope, code, = cli(fake, "login", "--setup", "--wait")

    assert_equal 0, code
    assert_equal [5, 20, 5], SetupTestBackend.sleeps
  end
end

class SetupLoginHumanTest < Minitest::Test
  include SetupTestHelpers

  def test_one_command_shows_the_code_waits_and_logs_in
    fake = FakeSetupAuth.new(polls: [PENDING, APPROVED])
    store.save(endpoint: "http://cp.test", token: "user.jwt.token", user: { "email" => "me@fresh.test" })

    out, = with_auth_client(fake) do
      capture_io { Vkit::CLI::Commands::SetupLoginCommand.new(endpoint: "http://cp.test").call }
    end

    assert_includes out, "BCDF-1231"
    assert_includes out, "http://console.test/setup/approve"
    assert_includes out, "Setup session approved by admin@fresh.test"
    assert_includes out, "replaced your saved login (me@fresh.test)"
    refute_includes out, TOKEN
    assert_equal TOKEN, saved["token"]
  end

  def test_no_browser
    fake = FakeSetupAuth.new(polls: [APPROVED])
    with_auth_client(fake) do
      capture_io { Vkit::CLI::Commands::SetupLoginCommand.new(endpoint: "http://cp.test", browser: false).call }
    end

    assert_empty SetupTestBackend.opened
  end
end

class SetupLogoutTest < Minitest::Test
  include SetupTestHelpers

  def save_setup_login
    store.save(endpoint: "http://cp.test", token: TOKEN, user: { "email" => "admin@fresh.test" },
               setup: { "expires_at" => "2026-11-25T12:30:00Z", "organization" => "fresh" })
  end

  def test_logout_revokes_the_setup_session_then_clears_it
    save_setup_login
    fake = FakeSetupAuth.new

    envelope, code, err, out = cli(fake, "logout")

    assert_equal 0, code
    assert_equal [TOKEN], fake.ended
    assert_equal true, envelope.dig("result", "setup_session_revoked")
    refute saved.key?("token")
    refute saved.key?("setup")
    refute_secrets(out, err)
  end

  def test_a_failed_revoke_still_clears_it_and_says_it_stays_valid
    save_setup_login
    fake = FakeSetupAuth.new(end_result: Errno::ECONNREFUSED.new)

    envelope, code, err, = cli(fake, "logout")

    assert_equal 0, code
    assert_equal false, envelope.dig("result", "setup_session_revoked")
    assert_includes envelope.dig("result", "warning"), "stays valid until it expires"
    assert_includes err, "stays valid until it expires"
    refute saved.key?("token")
  end

  def test_a_setup_session_the_control_plane_already_ended
    save_setup_login
    gone = Vkit::Core::AuthClient::HTTPError.new(401, JSON.dump(error: "expired", code: "setup_token_expired"))

    envelope, code, = cli(FakeSetupAuth.new(end_result: gone), "logout")

    assert_equal 0, code
    assert_equal true, envelope.dig("result", "already_ended")
  end

  def test_a_normal_login_logs_out_as_before
    store.save(endpoint: "http://cp.test", token: "user.jwt.token", user: {})
    fake = FakeSetupAuth.new

    cli(fake, "logout")

    assert_equal [:user_logout], fake.ended
  end
end

class SetupTokenErrorsTest < Minitest::Test
  include SetupTestHelpers

  def mapped(status, code)
    Vkit::CLI::ErrorMap.map(Vkit::CLI::API::APIError.from_body(status, { "error" => "msg", "code" => code }))
  end

  def test_the_control_plane_codes_map_to_setup_session_errors_with_fixes
    { "setup_token_expired" => "setup_session_expired", "setup_token_revoked" => "setup_session_revoked",
      "setup_token_invalid" => "setup_session_invalid",
      "setup_approver_not_admin" => "setup_approver_not_admin" }.each do |server, cli_code|
      error = mapped(401, server)
      assert_equal cli_code, error[:code]
      assert_includes error[:fix], "vkit login --setup"
    end
  end

  def test_out_of_scope_says_an_admin_must_sign_in_normally
    error = mapped(403, "setup_scope_forbidden")

    assert_equal "setup_scope_forbidden", error[:code]
    assert_includes error[:fix], "A setup session can't do this; an admin must"
    assert_includes error[:fix], "`vkit login`"
  end

  def test_new_409_codes_have_fixes
    %w[datasource_exists bundle_version_exists bundle_checksum_exists].each do |code|
      error = mapped(409, code)
      assert_equal code, error[:code]
      refute_includes error[:fix], "Read the control plane's message"
    end
  end

  def test_an_expired_saved_setup_session_fails_before_calling_the_control_plane
    store.save(endpoint: "http://cp.test", token: TOKEN, user: { "role" => "admin", "organization_slug" => "fresh" },
               setup: { "expires_at" => "2020-01-01T00:00:00Z", "organization" => "fresh" })

    out, code, = run_cli("datasource", "list", "--format", "json")
    envelope = JSON.parse(out)

    assert_equal 1, code
    assert_equal "setup_session_expired", envelope.dig("error", "code")
  end

  def test_whoami_shows_the_setup_session
    store.save(endpoint: "http://cp.test", token: TOKEN, user: {},
               setup: { "expires_at" => "2026-11-25T12:30:00Z", "organization" => "fresh" })
    fake = Object.new
    fake.define_singleton_method(:whoami) { |_t| { "email" => "admin@fresh.test", "role" => "admin" } }

    envelope, code, = cli(fake, "whoami")

    assert_equal 0, code
    assert_equal({ "expires_at" => "2026-11-25T12:30:00Z" }, envelope.dig("result", "setup_session"))
  end
end

class UserAgentTest < Minitest::Test
  # A one-request HTTP server; returns the request's headers.
  def capture_request
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    headers = nil
    thread = Thread.new do
      client = server.accept
      lines = []
      while (line = client.gets) && line != "\r\n"
        lines << line
      end
      headers = lines.drop(1).to_h { |l| k, v = l.split(":", 2); [k.downcase, v.strip] }
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
      client.close
    end
    yield "http://127.0.0.1:#{port}"
    thread.join(5)
    headers
  ensure
    server&.close
  end

  def test_the_api_client_sends_it
    headers = capture_request { |url| Vkit::CLI::API::Client.new(base_url: url, token: "t").get("/x") }

    assert_match %r{\Avkit/#{Regexp.escape(Vkit::VERSION)} \(\S+ \S+; ruby #{Regexp.escape(RUBY_VERSION)}\)\z},
                 headers["user-agent"]
  end

  def test_the_auth_client_sends_it
    headers = capture_request { |url| Vkit::Core::AuthClient.new(base_url: url).start_setup_session }

    assert_equal Vkit::Core::UserAgent.to_s, headers["user-agent"]
  end

  def test_os_names
    assert_equal "macOS", Vkit::Core::UserAgent.os_name("darwin25.5.0")
    assert_equal "Linux", Vkit::Core::UserAgent.os_name("linux-gnu")
    assert_equal "Windows", Vkit::Core::UserAgent.os_name("mingw32")
  end
end

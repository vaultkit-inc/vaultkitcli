# frozen_string_literal: true

# Run with: ruby -Ilib test/credential_override_test.rb
require "minitest/autorun"
require_relative "../lib/vkit/core/credential_store"

class CredentialOverrideTest < Minitest::Test
  FakeAuth = Struct.new(:calls) do
    def whoami(token)
      calls << token
      { "email" => "eng@demo.local", "organization_slug" => "demo" }
    end
  end

  def setup
    @saved_env = ENV.to_h.slice("VKIT_ENDPOINT", "VKIT_TOKEN")
    Vkit::Core::CredentialStore.override_noticed = false
  end

  def teardown
    %w[VKIT_ENDPOINT VKIT_TOKEN].each { |k| ENV.delete(k) }
    @saved_env.each { |k, v| ENV[k] = v }
  end

  # A store whose saved login must never be read.
  def store(auth = FakeAuth.new([]))
    s = Vkit::Core::CredentialStore.new
    s.define_singleton_method(:stored_payload) { raise "saved login was read" }
    s.define_singleton_method(:override_user) { |o| @override_user ||= auth.whoami(o["token"]) }
    s
  end

  def test_uses_both_variables_instead_of_the_saved_login
    ENV["VKIT_ENDPOINT"] = "http://localhost:3300"
    ENV["VKIT_TOKEN"] = "aaa.bbb.ccc"
    auth = FakeAuth.new([])
    s = store(auth)

    _, err = capture_io do
      assert s.logged_in?
      assert_equal "http://localhost:3300", s.endpoint
      assert_equal "aaa.bbb.ccc", s.token
      assert_empty auth.calls, "reading the token must not call the API"
      assert_equal "demo", s.user["organization_slug"]
      s.user
    end

    assert_equal ["aaa.bbb.ccc"], auth.calls, "the user is looked up once"
    assert_equal 1, err.lines.count
    assert_match(/using VKIT_ENDPOINT \(http:\/\/localhost:3300\) and VKIT_TOKEN from the environment/, err)
    refute_includes err, "aaa.bbb.ccc", "the token is never printed"
  end

  def test_prints_the_notice_once_per_process
    ENV["VKIT_ENDPOINT"] = "http://localhost:3300"
    ENV["VKIT_TOKEN"] = "t"

    _, err = capture_io do
      store.token
      store.endpoint
    end

    assert_equal 1, err.lines.count
  end

  def test_refuses_a_token_without_an_endpoint
    ENV["VKIT_TOKEN"] = "t"

    error = assert_raises(Vkit::CLI::Error) { store.token }

    assert_includes error.message, "VKIT_TOKEN is set but VKIT_ENDPOINT isn't"
    assert_includes error.message, "unset VKIT_TOKEN to use your saved login"
  end

  def test_refuses_an_endpoint_without_a_token
    ENV["VKIT_ENDPOINT"] = "http://localhost:3300"

    error = assert_raises(Vkit::CLI::Error) { store.logged_in? }

    assert_includes error.message, "VKIT_ENDPOINT is set but VKIT_TOKEN isn't"
  end

  def test_falls_back_to_the_saved_login_when_neither_is_set
    s = Vkit::Core::CredentialStore.new
    s.define_singleton_method(:stored_payload) { { "endpoint" => "https://saved", "token" => "saved-token", "user" => { "email" => "me" } } }

    out, err = capture_io { assert_equal "saved-token", s.token }

    assert_equal "", out + err
    assert_equal "me", s.user["email"]
  end

  def test_saving_the_user_with_the_override_leaves_the_saved_login_alone
    ENV["VKIT_ENDPOINT"] = "http://localhost:3300"
    ENV["VKIT_TOKEN"] = "t"
    s = store
    s.define_singleton_method(:mac_keychain_store) { |_| raise "saved login was written" }
    s.define_singleton_method(:file_store) { |_| raise "saved login was written" }

    capture_io { s.save_user({ "email" => "updated" }) }

    assert_equal "updated", s.user["email"]
  end
end

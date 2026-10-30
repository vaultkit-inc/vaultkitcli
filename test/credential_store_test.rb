# frozen_string_literal: true

# Run with: ruby -Ilib test/credential_store_test.rb
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/vkit/core/credential_store"

class CredentialStoreTest < Minitest::Test
  PAYLOAD = { "endpoint" => "https://vk.example", "token" => "aaa.bbb.ccc", "user" => { "type" => "user" } }.freeze

  Status = Struct.new(:ok) do
    def success? = ok
  end

  def setup
    @dir = Dir.mktmpdir
    @saved_env = ENV.to_h.slice("VKIT_ENDPOINT", "VKIT_TOKEN")
    %w[VKIT_ENDPOINT VKIT_TOKEN].each { |k| ENV.delete(k) }
  end

  def teardown
    FileUtils.rm_rf(@dir)
    @saved_env.each { |k, v| ENV[k] = v }
  end

  def fallback_path = File.join(@dir, ".vkit", "credentials.json")

  # Replaces Open3.capture3 for the block; result is a value or a lambda.
  def with_capture3(result)
    original = Open3.method(:capture3)
    Open3.define_singleton_method(:capture3) { |*a, **o| result.respond_to?(:call) ? result.call(*a, **o) : result }
    yield
  ensure
    Open3.define_singleton_method(:capture3, original)
  end

  # A store on the given OS whose keychain calls are the given lambdas.
  def store(os:, keychain_store: nil, keychain_load: nil)
    s = Vkit::Core::CredentialStore.new
    s.instance_variable_set(:@os, os)
    s.instance_variable_set(:@fallback_path, fallback_path)
    s.define_singleton_method(:secret_tool_available?) { true }
    if keychain_store
      s.define_singleton_method(:mac_keychain_store) { |p| keychain_store.call(p) }
      s.define_singleton_method(:linux_secret_service_store) { |p| keychain_store.call(p) }
    end
    if keychain_load
      s.define_singleton_method(:mac_keychain_load) { keychain_load.call }
      s.define_singleton_method(:linux_secret_service_load) { keychain_load.call }
    end
    s.define_singleton_method(:mac_keychain_delete) { nil }
    s.define_singleton_method(:linux_secret_service_delete) { nil }
    s
  end

  def save(s)
    s.save(endpoint: PAYLOAD["endpoint"], token: PAYLOAD["token"], user: PAYLOAD["user"])
  end

  def test_a_failed_keychain_save_falls_back_to_the_file_and_says_so
    %w[darwin linux-gnu].each do |os|
      s = store(os: os, keychain_store: ->(_) { false }, keychain_load: -> { nil })

      _, err = capture_io { save(s) }

      assert_match(/couldn't save to the system keychain; saved to #{Regexp.escape(fallback_path)}/, err)
      assert_equal PAYLOAD, JSON.parse(File.read(fallback_path))
      assert_equal 0o600, File.stat(fallback_path).mode & 0o777
      assert_equal "aaa.bbb.ccc", s.token, "the fallback login is read back on #{os}"
      FileUtils.rm_f(fallback_path)
    end
  end

  def test_a_keychain_save_removes_an_old_fallback_file
    FileUtils.mkdir_p(File.dirname(fallback_path))
    File.write(fallback_path, { "token" => "old" }.to_json)
    saved = nil
    s = store(os: "darwin", keychain_store: ->(p) { saved = p; true }, keychain_load: -> { saved })

    _, err = capture_io { save(s) }

    assert_empty err
    refute File.exist?(fallback_path)
    assert_equal "aaa.bbb.ccc", s.token
  end

  def test_without_a_keychain_saves_to_the_file_quietly
    s = store(os: "mingw32")

    _, err = capture_io { save(s) }

    assert_empty err
    assert_equal PAYLOAD, JSON.parse(File.read(fallback_path))
  end

  def test_clear_removes_the_fallback_file_too
    s = store(os: "darwin", keychain_store: ->(_) { false }, keychain_load: -> { nil })
    capture_io { save(s) }

    s.clear!

    refute File.exist?(fallback_path)
    refute s.logged_in?
  end

  def test_mac_keychain_store_keeps_the_token_off_the_command_line
    s = Vkit::Core::CredentialStore.new
    s.define_singleton_method(:mac_keychain_delete) { nil }
    calls = []
    fake = ->(*args, **opts) { calls << [args, opts]; ["", "", Status.new(true)] }

    with_capture3(fake) { assert s.mac_keychain_store(PAYLOAD) }

    args, opts = calls.first
    assert_equal %w[security -i], args
    refute(args.any? { |a| a.include?("aaa.bbb.ccc") })
    hex = opts[:stdin_data][/-X (\h+)\n\z/, 1]
    assert_equal PAYLOAD, JSON.parse([hex].pack("H*"))
  end

  def test_mac_keychain_store_reports_failure
    s = Vkit::Core::CredentialStore.new
    s.define_singleton_method(:mac_keychain_delete) { nil }

    with_capture3(["", "error", Status.new(false)]) { refute s.mac_keychain_store(PAYLOAD) }
  end

  def test_mac_keychain_store_refuses_a_payload_too_long_for_security
    s = Vkit::Core::CredentialStore.new
    s.define_singleton_method(:mac_keychain_delete) { raise "should not touch the keychain" }

    with_capture3(->(*) { raise "should not run security" }) do
      refute s.mac_keychain_store(PAYLOAD.merge("token" => "a" * 2_000))
    end
  end

  def test_linux_secret_service_store_reports_failure
    s = Vkit::Core::CredentialStore.new

    with_capture3(["", "Cannot autolaunch D-Bus", Status.new(false)]) do
      refute s.linux_secret_service_store(PAYLOAD)
    end
  end
end

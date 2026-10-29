# frozen_string_literal: true

# Run with: ruby -Ilib test/auth_client_test.rb
require "minitest/autorun"
require_relative "../lib/vkit/core/auth_client"

class AuthClientTlsTest < Minitest::Test
  def build_http(url)
    Vkit::Core::AuthClient.new(base_url: url).send(:build_http, URI(url))
  end

  def test_https_verifies_certificates
    http = build_http("https://cp.example.com")

    assert http.use_ssl?
    assert_includes [nil, OpenSSL::SSL::VERIFY_PEER], http.verify_mode
  end

  def test_plain_http_does_not_use_tls
    refute build_http("http://localhost:3000").use_ssl?
  end

  def test_no_client_disables_certificate_verification
    lib = File.expand_path("../lib", __dir__)
    offenders = Dir[File.join(lib, "**", "*.rb")].select do |file|
      File.read(file).include?("VERIFY_NONE")
    end

    assert_empty offenders
  end
end

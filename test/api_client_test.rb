# frozen_string_literal: true

# Run with: ruby -Ilib test/api_client_test.rb
require "minitest/autorun"
require "json"
require_relative "../lib/vkit/cli/api/client"

class APIClientErrorTest < Minitest::Test
  Response = Struct.new(:code, :body)

  def respond(status, body)
    client = Vkit::CLI::API::Client.new(base_url: "http://localhost:3300", token: "t")
    client.send(:handle_response, Response.new(status.to_s, body.is_a?(String) ? body : JSON.dump(body)))
  end

  def test_a_revoked_token_says_why_with_its_code_and_request_id
    error = assert_raises(Vkit::CLI::API::APIError) do
      respond(401, { "error" => "Agent token vkit_agent_f5f5d9 was revoked at 2026-11-04T19:55:11Z: Leaked",
                     "code" => "token_revoked", "request_id" => "7973fcba" })
    end

    assert_equal 401, error.status
    assert_equal "token_revoked", error.code
    assert_equal "7973fcba", error.request_id
    assert_equal <<~MSG.chomp, error.message
      API 401: Agent token vkit_agent_f5f5d9 was revoked at 2026-11-04T19:55:11Z: Leaked
      Code: token_revoked
      Request ID: 7973fcba (look it up under Activity in the console)
    MSG
  end

  def test_an_error_without_a_code_or_request_id_reads_as_before
    error = assert_raises(Vkit::CLI::API::APIError) { respond(422, { "error" => "A reason is required" }) }

    assert_equal "API 422: A reason is required", error.message
    assert_nil error.code
    assert_nil error.request_id
  end

  def test_a_non_json_error_body_is_kept_as_the_message
    error = assert_raises(Vkit::CLI::API::APIError) { respond(502, "Bad Gateway") }

    assert_equal "API 502: Bad Gateway", error.message
  end

  def test_a_policy_denial_is_still_a_response
    body = { "status" => "denied", "reason" => "No", "request_id" => "r1" }

    assert_equal body, respond(403, body)
  end
end

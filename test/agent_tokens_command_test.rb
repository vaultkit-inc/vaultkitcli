# frozen_string_literal: true

# Run with: ruby -Ilib test/agent_tokens_command_test.rb
require "minitest/autorun"
require "json"
require "time"
require_relative "../lib/vkit/cli/commands/base_command"
require_relative "../lib/vkit/cli/commands/agent_tokens_create_command"
require_relative "../lib/vkit/cli/commands/agent_tokens_revoke_command"

module AgentTokenTestHelpers
  # Records requests and returns canned responses.
  class FakeClient
    attr_reader :posts

    def initialize(get: {}, post: {})
      @get = get
      @post = post
      @posts = []
    end

    def get(_path, params: nil) # rubocop:disable Lint/UnusedMethodArgument
      @get
    end

    def post(path, body:)
      @posts << [path, body]
      @post
    end
  end

  FakeStore = Struct.new(:user) do
    def logged_in? = true
  end

  def wire(command, client)
    store = FakeStore.new({ "organization_slug" => "acme" })
    command.define_singleton_method(:credential_store) { store }
    command.define_singleton_method(:authenticated_client) { client }
    command
  end

  TOKEN = { "id" => "t1", "name" => "incident-bot", "prefix" => "vkit_agent_4c1e00", "role" => "agent" }.freeze
end

class AgentTokensCreateTest < Minitest::Test
  include AgentTokenTestHelpers

  def create(**options)
    client = FakeClient.new(post: { "token" => TOKEN.merge("label" => options[:label]), "secret" => "s3cret" })
    out, = capture_io { wire(Vkit::CLI::Commands::AgentTokensCreateCommand.new, client).call(name: "incident-bot", **options) }
    [out, client]
  end

  def test_sends_and_prints_the_label
    out, client = create(label: "PagerDuty runner")

    assert_equal [["/api/v1/orgs/acme/agent_tokens", { name: "incident-bot", label: "PagerDuty runner" }]], client.posts
    assert_includes out, "Label:      PagerDuty runner"
  end

  def test_leaves_the_label_out_unless_given
    out, client = create

    assert_equal({ name: "incident-bot" }, client.posts.first.last)
    refute_includes out, "Label:"
  end
end

class AgentTokensRevokeTest < Minitest::Test
  include AgentTokenTestHelpers

  def revoke(**options)
    client = FakeClient.new(get: { "tokens" => [TOKEN] })
    out, = capture_io do
      wire(Vkit::CLI::Commands::AgentTokensRevokeCommand.new, client).call(token: "vkit_agent_4c1e00", force: true, **options)
    end
    [out, client]
  end

  def test_sends_the_reason
    out, client = revoke(reason: "Leaked in CI logs")

    assert_equal [["/api/v1/orgs/acme/agent_tokens/t1/revoke", { reason: "Leaked in CI logs" }]], client.posts
    assert_includes out, "Reason: Leaked in CI logs"
  end

  def test_sends_no_reason_unless_given
    _, client = revoke

    assert_equal({}, client.posts.first.last)
  end
end

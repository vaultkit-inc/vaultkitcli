# frozen_string_literal: true

# Run with: ruby -Ilib test/agent_tokens_command_test.rb
require "minitest/autorun"
require "json"
require "time"
require_relative "../lib/vkit/cli"
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

  def create(acts_for: nil, registry: {}, **options)
    token = TOKEN.merge("label" => options[:label], "acts_for" => acts_for, "tenant" => options[:tenant])
    client = FakeClient.new(get: registry, post: { "token" => token, "secret" => "s3cret" })
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

  def test_sends_who_the_agent_acts_for_and_prints_them
    out, client = create(for: "sam@acme.test",
                         acts_for: { "id" => "u2", "name" => "Sam Patel", "email" => "sam@acme.test" })

    assert_equal({ name: "incident-bot", user_email: "sam@acme.test" }, client.posts.first.last)
    assert_includes out, "Acts for:   Sam Patel <sam@acme.test>"
  end

  def test_says_when_the_agent_acts_for_no_one
    out, client = create

    refute client.posts.first.last.key?(:user_email)
    assert_includes out, "Acts for:   no one"
  end
end

class AgentTokensTenantWarningTest < Minitest::Test
  include AgentTokenTestHelpers

  SCOPED = {
    "payments" => { "datasource" => "northstar", "tenant_column" => "organization_id", "fields" => {} },
    "invoices" => { "datasource" => "northstar", "tenant_column" => "organization_id", "fields" => {} },
    "plans" => { "datasource" => "northstar", "fields" => {} }
  }.freeze

  def create(registry:, client_class: FakeClient, **options)
    token = TOKEN.merge("tenant" => options[:tenant])
    client = client_class.new(get: registry, post: { "token" => token, "secret" => "s3cret" })
    out, = capture_io { wire(Vkit::CLI::Commands::AgentTokensCreateCommand.new, client).call(name: "incident-bot", **options) }
    out
  end

  def test_warns_when_a_token_without_a_tenant_meets_tenant_scoped_datasets
    out = create(registry: SCOPED)

    assert_includes out, "This token has no tenant, and 2 datasets are tenant-scoped in acme: invoices, payments."
    assert_includes out, "as if they didn't exist"
    assert_includes out, "--tenant"
  end

  def test_names_only_the_first_few
    registry = (1..8).to_h { |i| ["ds#{i}", { "tenant_column" => "org_id" }] }

    assert_includes create(registry: registry), "8 datasets are tenant-scoped in acme: ds1, ds2, ds3, ds4, ds5, and 3 more."
  end

  def test_no_warning_with_a_tenant
    refute_includes create(registry: SCOPED, tenant: "org_1"), "no tenant"
  end

  def test_no_warning_without_tenant_scoped_datasets
    refute_includes create(registry: { "plans" => { "fields" => {} } }), "no tenant"
  end

  class FailingExport < FakeClient
    def get(*) = raise("403 Forbidden")
  end

  def test_still_issues_the_token_when_the_registry_cannot_be_read
    out = create(registry: SCOPED, client_class: FailingExport)

    assert_includes out, "s3cret"
    refute_includes out, "no tenant"
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

  def test_refuses_to_revoke_without_a_reason
    error = assert_raises(RuntimeError) { revoke(reason: "  ") }

    assert_equal "A reason is required (--reason)", error.message
  end

  def test_the_reason_is_a_required_option
    tokens = Vkit::CLI::BaseCLI.subcommand_classes["agents"].subcommand_classes["tokens"]

    assert tokens.commands["revoke"].options[:reason].required
    assert Vkit::CLI::BaseCLI.commands["grant:revoke"].options[:reason].required
  end
end

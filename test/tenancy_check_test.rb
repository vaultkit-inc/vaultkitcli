# frozen_string_literal: true

# Run with: ruby -Ilib test/tenancy_check_test.rb
require "minitest/autorun"
require_relative "../lib/vkit/policy/tenancy_check"
require_relative "../lib/vkit/policy/bundle_compiler"
require_relative "../lib/vkit/cli/commands/base_command"
require_relative "../lib/vkit/cli/commands/agent_tokens_create_command"

class TenancyCheckTest < Minitest::Test
  def field(type = "text") = { "type" => type, "sensitivity" => "low", "category" => "internal" }

  def registry(**datasets)
    datasets.transform_keys(&:to_s)
  end

  def tickets(**extra)
    { "datasource" => "app", "tenant_column" => "organization_id",
      "fields" => { "id" => field, "organization_id" => field("uuid") } }.merge(extra.transform_keys(&:to_s))
  end

  def check(raw) = Vkit::Policy::TenancyCheck.call(raw)

  def test_accepts_a_tenant_column_that_is_a_field
    assert_empty check(registry(tickets: tickets))
  end

  def test_rejects_a_tenant_column_that_is_not_a_field
    errors = check(registry(tickets: tickets(tenant_column: "org_id")))

    assert_match(/tickets: tenant_column org_id isn't one of its fields/, errors.first)
  end

  def test_rejects_an_unmarked_dataset_with_another_datasets_tenant_column
    comments = { "datasource" => "app", "fields" => { "id" => field, "organization_id" => field("uuid") } }
    errors = check(registry(tickets: tickets, comments: comments))

    assert_equal 1, errors.size
    assert_match(/comments has organization_id, the tenant column of tickets, but no tenant_column/, errors.first)
  end

  def test_accepts_a_dataset_declared_shared_with_false
    organizations = { "datasource" => "app", "tenant_column" => false,
                      "fields" => { "id" => field, "organization_id" => field("uuid") } }

    assert_empty check(registry(tickets: tickets, organizations: organizations))
  end

  def test_rejects_other_values
    assert_match(/must be a field name, or false/, check(registry(tickets: tickets(tenant_column: true))).first)
  end

  def test_bundles_carry_the_tenant_column_but_not_false
    shared = { "datasource" => "app", "tenant_column" => false, "fields" => { "id" => field } }
    datasets = Vkit::Policy::BundleCompiler.normalize_registry(registry(tickets: tickets, plans: shared))["datasets"]

    assert_equal "organization_id", datasets.find { |d| d["name"] == "tickets" }["tenant_column"]
    refute datasets.find { |d| d["name"] == "plans" }.key?("tenant_column")
  end

  def test_token_requests_carry_tenant_clearance_and_region_only_when_given
    command = Vkit::CLI::Commands::AgentTokensCreateCommand.new

    assert_equal({ name: "assistant", role: "agent", tenant: "org_42", region: "EU" },
                 command.send(:build_body, { name: "assistant", role: "agent", tenant: "org_42", region: "EU" }))
    assert_equal({ name: "assistant", role: "agent" }, command.send(:build_body, { name: "assistant", role: "agent" }))
  end
end

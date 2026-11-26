# frozen_string_literal: true

# Run with: ruby -Ilib test/approval_groups_test.rb
require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "support/envelope"
require_relative "../lib/vkit/cli/commands/base_command"
require_relative "../lib/vkit/cli/commands/policy_deploy_command"
require_relative "../lib/vkit/policy/approval_groups"
require_relative "../lib/vkit/policy/policy_validator"
require_relative "../lib/vkit/policy/validation_error"

# Built-in role names can't be approval groups, and deploying a bundle that
# names a group nobody is in warns that org admins will approve for it.
class ApprovalGroupsTest < Minitest::Test
  Groups = Vkit::Policy::ApprovalGroups

  def bundle
    { "bundle" => { "bundle_version" => "v2" }, "policies" => [
      { "id" => "both", "action" => "require_approval",
        "approval" => { "approver_roles" => %w[security finance_manager], "approval_mode" => "all" } },
      { "id" => "owner", "action" => "require_approval", "approval" => { "approver_role" => "data_owner" } },
      { "id" => "masked", "action" => "mask" }
    ] }
  end

  def policy(action)
    { "id" => "p", "description" => "d",
      "action" => { "require_approval" => true, "reason" => "Needs review" }.merge(action) }
  end

  def test_rejects_built_in_roles_as_approver_groups
    error = assert_raises(Vkit::Policy::ValidationError) do
      Vkit::Policy::PolicyValidator.validate!(policy("approver_role" => "admin"))
    end
    assert_match(/admin is a built-in role, not an approval group/, error.message)

    error = assert_raises(Vkit::Policy::ValidationError) do
      Vkit::Policy::PolicyValidator.validate!(policy("approver_roles" => %w[security member agent]))
    end
    assert_match(/member, agent are built-in roles/, error.message)

    assert Vkit::Policy::PolicyValidator.validate!(policy("approver_roles" => %w[security data_owner]))
  end

  def test_names_groups_from_approver_role_and_approver_roles
    assert_equal %w[data_owner finance_manager security], Groups.named(bundle)
  end

  def test_warns_for_each_group_with_no_active_members
    listed = [
      { "name" => "finance_manager", "member_count" => 1, "active_member_count" => 1 },
      { "name" => "security", "member_count" => 0, "active_member_count" => 0 }
    ]

    assert_equal [
      { "code" => "approval_group_has_no_members", "group" => "data_owner",
        "message" => "data_owner has no members, so org admins will approve its requests until someone is added." },
      { "code" => "approval_group_has_no_members", "group" => "security",
        "message" => "security has no members, so org admins will approve its requests until someone is added." }
    ], Groups.warnings(bundle, listed)
  end

  def test_reads_member_count_from_older_control_planes
    listed = [{ "name" => "finance_manager", "member_count" => 2 }, { "name" => "security", "member_count" => 3 },
              { "name" => "data_owner", "member_count" => 1 }]

    assert_empty Groups.warnings(bundle, listed)
  end
end

class PolicyDeployWarningsTest < Minitest::Test
  include EnvelopeHelper

  class FakeClient
    attr_reader :gets

    def initialize(post:, get: nil)
      @post = post
      @get = get
      @gets = []
    end

    def post(_path, body:) = @post # rubocop:disable Lint/UnusedMethodArgument

    def get(path, params: {}) # rubocop:disable Lint/UnusedMethodArgument
      @gets << path
      raise @get if @get.is_a?(Exception)

      @get
    end
  end

  FakeStore = Struct.new(:user) do
    def logged_in? = true
  end

  WARNING = { "code" => "approval_group_has_no_members", "group" => "security",
              "message" => "security has no members, so org admins will approve its requests until someone is added." }.freeze

  def deploy(client, format: "human")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bundle.json")
      File.write(path, JSON.generate("bundle" => { "bundle_version" => "v2" }, "policies" => [
        { "id" => "p", "action" => "require_approval", "approval" => { "approver_role" => "security" } }
      ]))
      command = Vkit::CLI::Commands::PolicyDeployCommand.new
      store = FakeStore.new({ "organization_slug" => "acme" })
      command.define_singleton_method(:credential_store) { store }
      command.define_singleton_method(:authenticated_client) { client }
      if format == "json"
        envelope, = run_json { command.call(bundle_path: path, org: nil, activate: true, format: format) }
        return envelope
      end

      out, = capture_io { command.call(bundle_path: path, org: nil, activate: true, format: format) }
      out
    end
  end

  def deployed(**extra)
    { "status" => "ok", "bundle_version" => "v2", "checksum" => "abc", "state" => "active" }.merge(extra)
  end

  def test_prints_the_control_planes_warnings
    client = FakeClient.new(post: deployed("warnings" => [WARNING]))
    out = deploy(client)

    assert_match(/Policy bundle deployed/, out)
    assert_match(/⚠️  security has no members, so org admins will approve its requests until someone is added\./, out)
    assert_empty client.gets
  end

  def test_prints_nothing_extra_without_warnings
    out = deploy(FakeClient.new(post: deployed("warnings" => [])))

    refute_match(/⚠️/, out)
  end

  def test_json_output_carries_the_warnings
    envelope = deploy(FakeClient.new(post: deployed("warnings" => [WARNING])), format: "json")

    assert_equal "ok", envelope["status"]
    assert_equal({ "org" => "acme", "bundle_version" => "v2", "state" => "active", "checksum" => "abc",
                   "warnings" => [WARNING], "already_deployed" => false }, envelope["result"])
  end

  def test_applies_the_same_rule_for_older_control_planes
    client = FakeClient.new(post: deployed, get: { "groups" => [{ "name" => "security", "member_count" => 0 }] })
    envelope = deploy(client, format: "json")

    assert_equal ["/api/v1/orgs/acme/approval_groups"], client.gets
    assert_equal [WARNING], envelope.dig("result", "warnings")
  end

  def test_a_failure_to_list_groups_never_fails_the_deploy
    envelope = deploy(FakeClient.new(post: deployed, get: RuntimeError.new("boom")), format: "json")

    assert_equal [], envelope.dig("result", "warnings")
  end
end

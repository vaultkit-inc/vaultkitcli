# frozen_string_literal: true

# Run with: ruby -Ilib test/approval_commands_test.rb
require "minitest/autorun"
require "json"
require_relative "../lib/vkit/cli/commands/base_command"
require_relative "../lib/vkit/cli/commands/approval_command"
require_relative "../lib/vkit/cli/commands/approval_watch_command"

module ApprovalTestHelpers
  # Records requests and returns canned responses.
  class FakeClient
    attr_reader :posts

    def initialize(get: [], post: {})
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

  def pending_dual(**extra)
    {
      "id" => "42", "dataset" => "payroll", "fields" => %w[amount ssn], "requester" => "user:analyst@acme.test",
      "approver_role" => "finance_manager, security", "approver_roles" => %w[finance_manager security],
      "approved_roles" => ["finance_manager"], "outstanding_roles" => ["security"],
      "state" => "pending", "reason" => "Payroll data", "created_at" => "2026-10-28T02:00:00Z"
    }.merge(extra)
  end
end

class ApprovalApproveTest < Minitest::Test
  include ApprovalTestHelpers

  def approve(response, **kwargs)
    client = FakeClient.new(post: response)
    out, = capture_io { wire(Vkit::CLI::Commands::ApprovalCommand.new, client).call_approve(id: "42", **kwargs) }
    [out, client]
  end

  def test_prints_the_outstanding_roles_after_a_partial_sign_off
    out, = approve({ "status" => "pending", "approved_roles" => ["finance_manager"], "outstanding_roles" => ["security"] })

    assert_includes out, "Signed off on request 42"
    assert_includes out, "Approved by: finance_manager"
    assert_includes out, "Waiting on:  security"
    refute_includes out, "Grant Ref"
  end

  def test_prints_the_grant_once_every_role_has_approved
    out, = approve({ "status" => "approved", "grant_ref" => "g_1", "expires_at" => "2026-10-28T04:00:00Z" })

    assert_includes out, "Approved request 42"
    assert_includes out, "Grant Ref: g_1"
    refute_includes out, "Waiting on"
  end

  def test_leaves_the_ttl_to_the_policy_unless_given
    _, client = approve({ "status" => "approved" })
    assert_equal [["/api/v1/orgs/acme/approvals/42/approve", {}]], client.posts

    _, client = approve({ "status" => "approved" }, ttl_seconds: 600)
    assert_equal({ ttl_seconds: 600 }, client.posts.first.last)
  end
end

class ApprovalListTest < Minitest::Test
  include ApprovalTestHelpers

  def list(rows)
    out, = capture_io { wire(Vkit::CLI::Commands::ApprovalCommand.new, FakeClient.new(get: rows)).call_list }
    out
  end

  def test_shows_every_required_role_and_the_ones_still_waiting
    out = list([pending_dual])

    assert_includes out, "Required:   finance_manager, security"
    assert_includes out, "Waiting on: security"
    assert_includes out, "Requester:  user:analyst@acme.test"
  end

  def test_skips_the_waiting_line_before_anyone_has_signed
    out = list([pending_dual("approved_roles" => [], "outstanding_roles" => %w[finance_manager security])])

    assert_includes out, "Required:   finance_manager, security"
    refute_includes out, "Waiting on"
  end

  def test_reads_the_single_role_from_older_control_planes
    out = list([{ "id" => "7", "dataset" => "payroll", "fields" => ["amount"], "approver_role" => "finance_manager",
                  "state" => "pending", "created_at" => "2026-10-28T02:00:00Z" }])

    assert_includes out, "Required:   finance_manager"
    refute_includes out, "Waiting on"
  end
end

class ApprovalWatchTest < Minitest::Test
  include ApprovalTestHelpers

  def watch
    Vkit::CLI::Commands::ApprovalWatchCommand.new
  end

  def test_json_events_carry_required_and_outstanding_roles
    event = watch.send(:normalize, pending_dual)

    assert_equal %w[finance_manager security], event[:approver_roles]
    assert_equal ["security"], event[:outstanding_roles]
    assert_equal "finance_manager, security", event[:approver_role]
  end

  def test_json_events_from_older_control_planes_fall_back_to_approver_role
    event = watch.send(:normalize, { "id" => "7", "approver_role" => "security", "state" => "pending" })

    assert_equal ["security"], event[:approver_roles]
    assert_equal ["security"], event[:outstanding_roles]
  end

  def test_table_output_shows_roles_and_who_is_still_needed
    out, = capture_io { watch.send(:render_human, pending_dual) }

    assert_includes out, "Role Req:  finance_manager, security"
    assert_includes out, "Waiting:   security"
  end
end

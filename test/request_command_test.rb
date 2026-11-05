# frozen_string_literal: true

# Run with: ruby -Ilib test/request_command_test.rb
require "minitest/autorun"
require "json"
require_relative "../lib/vkit/cli/commands/base_command"
require_relative "../lib/vkit/cli/commands/request_command"

class RequestCommandResultTest < Minitest::Test
  def handle(result, format: "table")
    status = nil
    out, = capture_io do
      Vkit::CLI::Commands::RequestCommand.new.send(:handle_result, result, { format: format })
    rescue SystemExit => e
      status = e.status
    end
    [out, status]
  end

  def pending(overrides = {})
    {
      "status" => "pending_approval",
      "request_id" => "req_7f3c",
      "approver_role" => "finance_manager, security",
      "approver_roles" => %w[finance_manager security],
      "reason" => "Payroll data"
    }.merge(overrides)
  end

  def test_pending_approval_prints_queued_with_request_id_and_roles
    out, status = handle(pending)

    assert_equal 0, status
    assert_includes out, "QUEUED for approval"
    assert_includes out, "Request ID: req_7f3c"
    assert_includes out, "Approver roles: finance_manager, security"
    assert_includes out, "Reason: Payroll data"
    assert_includes out, "Once it's approved, run the same request again to get the data."
    refute_includes out, "Unexpected response"
  end

  def test_reads_the_single_role_from_older_control_planes
    out, = handle(pending("approver_roles" => nil, "approver_role" => "data_owner", "reason" => nil))

    assert_includes out, "Approver roles: data_owner"
    refute_includes out, "Reason:"
  end

  def test_still_handles_the_old_queued_status
    out, status = handle({ "status" => "queued", "request_id" => "req_1" })

    assert_equal 0, status
    assert_includes out, "QUEUED for approval"
    assert_includes out, "Request ID: req_1"
    refute_includes out, "Approver roles:"
  end

  def test_json_format_prints_the_response_unchanged
    out, status = handle(pending, format: "json")

    assert_equal 0, status
    assert_equal "pending_approval", JSON.parse(out)["status"]
  end

  def test_unknown_statuses_are_still_reported
    out, status = handle({ "status" => "mystery" })

    assert_equal 1, status
    assert_includes out, "Unexpected response"
  end

  def test_granted_prints_the_grant_ref_and_request_id
    out, status = handle({ "status" => "granted", "request_id" => "8d1c0a2e", "grant_ref" => "g_orders_dfdf",
                           "expires_at" => "2026-11-04T21:00:00Z", "masked_fields" => [] })

    assert_equal 0, status
    assert_includes out, "Grant Ref: g_orders_dfdf"
    refute_match(/Grant ID:\s*$/, out)
    assert_includes out, "Request ID: 8d1c0a2e (look it up under Activity in the console)"
    assert_includes out, "vkit fetch --grant g_orders_dfdf"
  end

  def test_denied_prints_the_request_id
    out, status = handle({ "status" => "denied", "reason" => "Secrets never leave", "request_id" => "7f29e0aa" })

    assert_equal 2, status
    assert_includes out, "Reason: Secrets never leave"
    assert_includes out, "Request ID: 7f29e0aa"
  end

  def test_rows_print_the_request_id_and_the_reused_grant
    out, = handle({ "status" => "ok", "reused" => true, "request_id" => "7f2a91aa", "grant_ref" => "g_orders_dfdf",
                    "rows" => [], "meta" => {} })

    assert_includes out, "Grant Ref: g_orders_dfdf (reused)"
    assert_includes out, "Request ID: 7f2a91aa"
  end

  def test_leaves_the_request_id_out_when_there_is_none
    out, = handle({ "status" => "denied", "reason" => "No" })

    refute_includes out, "Request ID"
  end
end

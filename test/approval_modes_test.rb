# frozen_string_literal: true

# Run with: ruby -Ilib test/approval_modes_test.rb
require "minitest/autorun"
require "yaml"
require_relative "../lib/vkit/policy/bundle_compiler"
require_relative "../lib/vkit/policy/match_check"
require_relative "../lib/vkit/policy/policy_validator"
require_relative "../lib/vkit/policy/validation_error"

# Several approver groups in one policy (approver_roles, approval_mode all |
# any), match.fields.usage, and the packs that use them.
class ApprovalModesTest < Minitest::Test
  PACKS = File.expand_path("../lib/vkit/policy/packs", __dir__)
  Validator = Vkit::Policy::PolicyValidator

  def policy(action)
    { "id" => "p", "description" => "d",
      "action" => { "require_approval" => true, "reason" => "Needs review" }.merge(action) }
  end

  def validate(action) = Validator.validate!(policy(action))

  def assert_invalid(action, pattern)
    error = assert_raises(Vkit::Policy::ValidationError) { validate(action) }
    assert_match pattern, error.message
  end

  def test_accepts_one_group_or_several_with_a_mode
    assert validate("approver_role" => "security")
    assert validate("approver_roles" => %w[security data_owner])
    assert validate("approver_roles" => %w[security data_owner], "approval_mode" => "any")
    assert validate("approver_roles" => %w[security data_owner], "approval_mode" => "all")
  end

  def test_rejects_an_unknown_mode
    assert_invalid({ "approver_roles" => %w[security data_owner], "approval_mode" => "some" },
                   /approval_mode must be all .* or any/)
  end

  def test_rejects_both_forms_an_empty_list_a_repeated_group_and_a_mode_without_groups
    assert_invalid({ "approver_role" => "security", "approver_roles" => ["data_owner"] }, /not both/)
    assert_invalid({ "approver_roles" => [] }, /must be a list of approver group names/)
    assert_invalid({ "approver_roles" => ["security", " "] }, /must be a list of approver group names/)
    assert_invalid({ "approver_roles" => %w[security security] }, /more than once/)
    assert_invalid({ "approver_role" => "security", "approval_mode" => "any" }, /only applies to approver_roles/)
    assert_invalid({}, /approver_role is required/)
  end

  def test_compiles_one_group_as_before_and_several_with_their_mode
    single = Vkit::Policy::BundleCompiler.extract_approval(policy("approver_role" => "security"))
    several = Vkit::Policy::BundleCompiler.extract_approval(policy("approver_roles" => %w[security data_owner]))
    either = Vkit::Policy::BundleCompiler.extract_approval(
      policy("approver_roles" => %w[security data_owner], "approval_mode" => "any")
    )

    assert_equal({ "approver_role" => "security" }, single)
    assert_equal({ "approver_roles" => %w[security data_owner], "approval_mode" => "all" }, several)
    assert_equal "any", either["approval_mode"]
  end

  def test_match_check_knows_usage
    registry = { "datasets" => [{ "name" => "payments", "fields" => [{ "name" => "amount", "tags" => ["financial"] }] }] }
    check = ->(usage) {
      Vkit::Policy::MatchCheck.call([{ "id" => "p", "match" => { "fields" => { "contains" => ["financial"], "usage" => usage } } }],
                                    registry).errors
    }

    assert_empty check.call("row")
    assert_empty check.call("aggregate")
    assert(check.call("rows").any? { |e| e.include?("usage rows isn't one of: row, aggregate") })
  end

  def pack_policy(pack, file) = YAML.safe_load(File.read(File.join(PACKS, pack, "policies", file)))

  def test_financial_approvals_cover_row_level_reads_only
    finance = pack_policy("financial_compliance", "01_require_approval_financial_prod.yaml")
    agents = pack_policy("ai_safety", "04_require_approval_agents_financial_prod.yaml")

    assert_equal "row", finance.dig("match", "fields", "usage")
    assert_equal "row", agents.dig("match", "fields", "usage")
  end

  def test_ai_safety_financial_review_is_met_by_the_finance_sign_off
    agents = pack_policy("ai_safety", "04_require_approval_agents_financial_prod.yaml")

    assert_equal %w[security finance_manager], agents.dig("action", "approver_roles")
    assert_equal "any", agents.dig("action", "approval_mode")
    assert Validator.validate!(agents)
  end

  def test_ai_safety_personal_data_review_no_longer_covers_financial_data
    sensitive = pack_policy("ai_safety", "01_require_approval_agents_sensitive_prod.yaml")

    assert_equal ["pii"], sensitive.dig("match", "fields", "contains")
    assert_nil sensitive.dig("match", "fields", "usage")
  end
end

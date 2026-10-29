# frozen_string_literal: true

# Run with: ruby -Ilib test/match_check_test.rb
require "minitest/autorun"
require "yaml"
require_relative "../lib/vkit/policy/match_check"
require_relative "../lib/vkit/policy/policy_validator"
require_relative "../lib/vkit/policy/validation_error"

class MatchCheckTest < Minitest::Test
  REGISTRY = {
    "datasets" => [
      { "name" => "customers", "fields" => [
        { "name" => "email", "sensitivity" => "medium", "tags" => ["pii"] },
        { "name" => "segment", "sensitivity" => "low", "tags" => ["marketing"] }
      ] }
    ]
  }.freeze

  PACKS = File.expand_path("../lib/vkit/policy/packs", __dir__)

  def check(policy)
    Vkit::Policy::MatchCheck.call([{ "id" => "p", "action" => { "allow" => true } }.merge(policy)], REGISTRY)
  end

  def assert_error(policy, pattern)
    errors = check(policy).errors
    assert errors.any? { |e| e.match?(pattern) }, "expected an error matching #{pattern}, got #{errors.inspect}"
  end

  def test_accepts_classifier_tags_and_registry_tags
    assert_empty check("match" => { "fields" => { "contains" => %w[credential pii marketing unknown] } }).errors
  end

  def test_accepts_the_unknown_sensitivity_before_any_column_has_it
    assert_empty check("match" => { "fields" => { "sensitivity" => "unknown" } }).errors
  end

  def test_rejects_tags_no_field_can_have
    assert_error({ "match" => { "fields" => { "contains" => %w[pii pci] } } }, /no field has the tag pci/)
  end

  def test_rejects_the_category_key_the_engine_ignores
    assert_error({ "match" => { "fields" => { "category" => "financial" } } }, /category isn't supported.*contains/)
  end

  def test_rejects_unknown_match_keys_and_sensitivities
    assert_error({ "match" => { "table" => "customers" } }, /match.table isn't supported/)
    assert_error({ "match" => { "fields" => { "sensitivity" => "pii" } } }, /sensitivity pii never occurs/)
  end

  def test_rejects_datasets_missing_from_the_registry
    assert_error({ "match" => { "dataset" => "custmers" } }, /dataset custmers isn't in datasets\/registry.yaml/)
    assert_empty check("match" => { "dataset" => "customers" }).errors
  end

  def test_accepts_admin_set_clearance_and_region
    assert_empty check("context" => { "requester_clearance" => "low", "requester_region" => "US",
                                      "dataset_region" => "EU" }).errors
  end

  def test_rejects_clearances_and_regions_admins_cannot_set
    assert_error({ "context" => { "requester_clearance" => "secret" } }, /requester_clearance secret isn't one of: low, medium, high/)
    assert_error({ "match" => { "context" => { "requester_region" => "Mars" } } }, /match.context.requester_region Mars/)
  end

  def test_rejects_time_windows_where_the_engine_ignores_them
    assert_error({ "context" => { "time" => { "after" => "09:00" } } }, /time only works under match.context/)
    assert_empty check("match" => { "context" => { "time" => { "after" => "09:00" } } }).errors
  end

  def test_rejects_environments_and_regions_that_dont_exist
    assert_error({ "context" => { "environment" => "prod" } }, /environment prod isn't one of/)
    assert_error({ "context" => { "dataset_region" => "eu" } }, /dataset_region eu isn't one of/)
  end

  def test_rejects_a_mask_policy_with_no_fields_to_mask
    assert_error({ "action" => { "mask" => true }, "match" => {} }, /mask policy needs match.fields/)
  end

  def test_every_shipped_pack_policy_is_valid_and_can_match
    files = Dir[File.join(PACKS, "*", "policies", "*.yaml")]
    refute_empty files

    policies = files.map do |file|
      policy = YAML.load_file(file)
      Vkit::Policy::PolicyValidator.validate!(policy, file: File.basename(file))
      policy.merge("__file" => File.basename(file))
    end
    # An empty registry: the packs must rely only on the classifier's labels.
    result = Vkit::Policy::MatchCheck.call(policies, { "datasets" => [] })

    assert_empty result.errors
  end

  def test_catches_the_v1_pack_policies_that_never_fired
    v1 = [
      { "id" => "fin_require_approval_financial_prod", "match" => { "fields" => { "category" => "financial" } } },
      { "id" => "fin_deny_non_admin_pci_prod", "match" => { "fields" => { "contains" => ["pci"] } } },
      { "id" => "ai_mask_sensitive_for_agents", "match" => { "fields" => { "contains" => %w[pii financial phi secrets] } } }
    ]
    errors = Vkit::Policy::MatchCheck.call(v1, { "datasets" => [] }).errors

    assert_equal 3, errors.size
  end
end

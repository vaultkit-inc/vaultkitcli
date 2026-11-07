# frozen_string_literal: true

# Run with: ruby -Ilib test/starter_pack_test.rb
require "minitest/autorun"
require "tmpdir"
require "yaml"
require_relative "../lib/vkit/policy/policy_validator"
require_relative "../lib/vkit/policy/bundle_compiler"
require_relative "../lib/vkit/cli/policy_pack/manager"

# The starter pack masks unknown columns for agents (vaultkitcli#45). The
# control plane evaluates the compiled policies, so these check what the
# bundle carries; the control plane's specs evaluate the same shape.
class StarterPackTest < Minitest::Test
  REGISTRY = {
    "datasets" => {
      "customers" => {
        "datasource" => "app",
        "fields" => {
          "id" => { "type" => "uuid", "sensitivity" => "low", "category" => "internal" },
          "email" => { "type" => "text", "sensitivity" => "medium", "category" => "pii" },
          "notes" => { "type" => "text", "sensitivity" => "unknown", "category" => "unknown" }
        }
      }
    }
  }.freeze

  def setup
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, ".vkit"))
    FileUtils.mkdir_p(File.join(@dir, "datasets"))
    File.write(File.join(@dir, "datasets", "registry.yaml"), REGISTRY.to_yaml)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def manager
    Vkit::CLI::PolicyPack::Manager.new(project_root: @dir)
  end

  def compile
    Dir.chdir(@dir) do
      Vkit::Policy::BundleCompiler.compile!(
        org_slug: "acme", bundle_version: "1",
        policies_dir: File.join(@dir, "config", "policies"), registry_dir: File.join(@dir, "datasets")
      )
    end
  end

  def policy(bundle, id)
    bundle["policies"].find { |p| p["id"] == id }
  end

  def test_masks_unknown_columns_fully_for_agents_in_every_environment
    manager.install!("starter")
    mask = policy(compile, "mask_unknown_for_agents")

    assert mask, "starter should ship mask_unknown_for_agents"
    assert_equal "mask", mask["action"]
    assert_equal({ "fields" => { "sensitivity" => "unknown" } }, mask["match"])
    assert_equal({ "requester_role" => "agent" }, mask["when"])
    assert_equal "full", mask.dig("masking", "default_method")
  end

  def test_people_still_get_unknown_columns_allowed_and_flagged
    manager.install!("starter")
    flag = policy(compile, "flag_unknown_sensitivity")

    assert_equal "allow", flag["action"]
    refute flag.key?("when"), "the flag applies to everyone; only the mask is limited to agents"
  end

  def test_ai_safety_still_requires_approval_for_agents_on_unknown_in_production
    manager.install!("starter")
    manager.install!("ai_safety")
    bundle = compile
    approval = policy(bundle, "ai_require_approval_agents_unknown_prod")

    assert_equal "require_approval", approval["action"]
    assert_equal({ "environment" => "production", "requester_role" => "agent" }, approval["when"])
    # Both match an agent in production: approval is the stronger decision,
    # and the mask still applies after approval.
    assert policy(bundle, "mask_unknown_for_agents")
  end

  def test_upgrading_from_2_0_0_adds_the_mask_policy
    manager.install!("starter")
    path = File.join(@dir, ".vkit", "packs.yaml")
    state = YAML.safe_load(File.read(path))
    state["installed_packs"]["starter"]["version"] = "2.0.0"
    File.write(path, state.to_yaml)

    result = manager.upgrade!("starter")

    assert_equal "2.0.0", result[:old_version]
    assert_equal "2.1.0", result[:new_version]
    assert(Dir[File.join(@dir, "config", "policies", "starter__*__mask_unknown_for_agents.yaml")].any?)
  end
end

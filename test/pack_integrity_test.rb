# frozen_string_literal: true

# Run with: ruby -Ilib test/pack_integrity_test.rb
require "minitest/autorun"
require "tmpdir"
require "yaml"
require "json"
require_relative "../lib/vkit/policy/bundle_compiler"
require_relative "../lib/vkit/cli/policy_pack/manager"

class PackIntegrityTest < Minitest::Test
  Compiler = Vkit::Policy::BundleCompiler
  PACKS = %w[starter ai_safety financial_compliance].freeze

  REGISTRY = {
    "customers" => {
      "datasource" => "main",
      "tenant_column" => "merchant_id",
      "fields" => {
        "merchant_id" => { "type" => "text", "sensitivity" => "low", "category" => "identifier" },
        "email" => { "type" => "text", "sensitivity" => "medium", "category" => "pii" },
        "password_hash" => { "type" => "text", "sensitivity" => "critical", "category" => "credential" },
        "card_last4" => { "type" => "text", "sensitivity" => "high", "category" => "financial" },
        "notes" => { "type" => "text", "sensitivity" => "unknown", "category" => "unknown" }
      }
    }
  }.freeze

  REPO_POLICY = {
    "id" => "allow_support_reads",
    "description" => "Support may read customers.",
    "priority" => 10,
    "match" => { "dataset" => "customers" },
    "action" => { "allow" => true }
  }.freeze

  def setup
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, ".vkit"))
    FileUtils.mkdir_p(File.join(@dir, "datasets"))
    File.write(File.join(@dir, "datasets", "registry.yaml"), REGISTRY.to_yaml)
    manager = Vkit::CLI::PolicyPack::Manager.new(project_root: @dir)
    PACKS.each { |pack| manager.install!(pack) }
    File.write(File.join(policies_dir, "allow_support_reads.yaml"), REPO_POLICY.to_yaml)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def policies_dir
    File.join(@dir, "config", "policies")
  end

  def compile
    Compiler.compile!(org_slug: "acme", bundle_version: "v1", policies_dir: policies_dir,
                      registry_dir: File.join(@dir, "datasets"), project_root: @dir)
  end

  def pack_file(pack, id)
    Dir[File.join(policies_dir, "#{pack}__*__#{id}.yaml")].first or flunk "no #{pack} file for #{id}"
  end

  def tracking
    YAML.safe_load(File.read(File.join(@dir, ".vkit", "packs.yaml")))
  end

  def assert_bundle_fails(pattern)
    error = assert_raises(Vkit::Policy::ValidationError) { compile }
    assert_match pattern, error.message
    error
  end

  def test_a_complete_repo_bundles_every_pack_policy_and_records_them
    bundle = compile
    ids = bundle["policies"].map { |p| p["id"] }
    packs = bundle.dig("bundle", "installed_packs")

    assert_equal 12, ids.length
    assert_includes ids, "deny_credentials"
    assert_includes ids, "allow_support_reads"
    assert_equal PACKS.sort, packs.map { |p| p["name"] }.sort
    starter = packs.find { |p| p["name"] == "starter" }
    assert_equal "2.0.0", starter["version"]
    assert_equal 6, starter["policy_ids"].length
    assert_includes starter["policy_ids"], "deny_credentials"
  end

  def test_a_deleted_pack_file_fails_naming_the_pack_and_file
    File.delete(pack_file("starter", "deny_credentials"))

    error = assert_bundle_fails(/starter 2\.0\.0:/)
    assert_match %r{missing config/policies/starter__01__deny_credentials\.yaml \(deny_credentials\)}, error.message
    refute_match(/ai_safety/, error.message)
  end

  def test_every_pack_file_deleted_fails_for_every_pack
    Dir[File.join(policies_dir, "*__*.yaml")].each { |f| File.delete(f) }

    error = assert_bundle_fails(/incomplete/)
    PACKS.each { |pack| assert_match(/^  #{pack} 2\.0\.0:/, error.message) }
    assert_equal 11, error.message.scan(/    - missing /).length
  end

  def test_a_pack_file_from_another_version_fails
    path = pack_file("starter", "mask_pii_by_default")
    File.write(path, File.read(path).sub("# Pack Version: 2.0.0", "# Pack Version: 1.4.0"))

    assert_bundle_fails(/starter__02__mask_pii_by_default\.yaml is from version 1\.4\.0, but 2\.0\.0 is installed/)
  end

  def test_a_tracking_file_that_lost_entries_fails
    state = tracking
    state["installed_packs"]["starter"]["files"].shift
    File.write(File.join(@dir, ".vkit", "packs.yaml"), state.to_yaml)

    assert_bundle_fails(/records 5 of the pack's 6 policies \(not recorded: deny_credentials\)/)
  end

  def test_a_pack_file_whose_policy_id_changed_fails
    path = pack_file("starter", "deny_credentials")
    File.write(path, File.read(path).sub(/^id: deny_credentials$/, "id: deny_secrets"))

    assert_bundle_fails(/has policy id "deny_secrets", recorded as "deny_credentials"/)
  end

  def test_pack_files_outside_the_policies_dir_fail
    other = File.join(@dir, "other")
    FileUtils.mkdir_p(other)
    File.write(File.join(other, "allow_support_reads.yaml"), REPO_POLICY.to_yaml)

    error = assert_raises(Vkit::Policy::ValidationError) do
      Compiler.compile!(org_slug: "acme", bundle_version: "v1", policies_dir: other,
                        registry_dir: File.join(@dir, "datasets"), project_root: @dir)
    end
    assert_match(/is not in the policies directory/, error.message)
  end

  def test_an_unreadable_tracking_file_fails_instead_of_dropping_every_pack
    File.write(File.join(@dir, ".vkit", "packs.yaml"), "installed_packs: [unclosed")

    assert_bundle_fails(/Can't read \.vkit\/packs\.yaml/)
  end

  def test_a_repo_without_packs_still_bundles
    FileUtils.rm_rf(File.join(@dir, ".vkit"))
    Dir[File.join(policies_dir, "*__*.yaml")].each { |f| File.delete(f) }

    bundle = compile
    assert_equal ["allow_support_reads"], bundle["policies"].map { |p| p["id"] }
    assert_equal [], bundle.dig("bundle", "installed_packs")
  end

  def test_an_edited_pack_policy_still_bundles
    path = pack_file("starter", "deny_credentials")
    File.write(path, File.read(path).sub(/^priority: 95$/, "priority: 96"))

    assert_equal 96, compile["policies"].find { |p| p["id"] == "deny_credentials" }["priority"]
  end

  # Bundles built before policy_ids existed are checked against the shipped pack.
  def test_check_bundle_catches_an_old_bundle_without_a_pack_policy
    bundle = compile
    bundle["policies"].reject! { |p| p["id"] == "deny_credentials" }
    bundle["bundle"]["installed_packs"].each { |p| p.delete("policy_ids") }

    error = assert_raises(Vkit::Policy::ValidationError) { Vkit::Policy::PackIntegrity.check_bundle!(bundle) }
    assert_match(/starter 2\.0\.0:\n    - missing policies: deny_credentials/, error.message)
  end

  def test_check_bundle_catches_a_new_bundle_without_a_pack_policy
    bundle = compile
    bundle["policies"].reject! { |p| p["id"].start_with?("ai_") }

    error = assert_raises(Vkit::Policy::ValidationError) { Vkit::Policy::PackIntegrity.check_bundle!(bundle) }
    assert_match(/ai_safety 2\.0\.0:\n    - missing policies: ai_require_approval_agents/, error.message)
  end

  def test_check_bundle_accepts_a_complete_bundle_and_unknown_pack_versions
    bundle = compile
    Vkit::Policy::PackIntegrity.check_bundle!(bundle)

    bundle["bundle"]["installed_packs"] = [{ "name" => "starter", "version" => "1.0.0" }]
    Vkit::Policy::PackIntegrity.check_bundle!(bundle)
  end

  def test_the_bundle_matches_the_schema
    require "json_schemer"
    schema = JSON.parse(File.read(File.expand_path("../lib/vkit/policy/schema/policy_bundle.schema.json", __dir__)))
    bundle = JSON.parse(JSON.generate(compile))

    assert_empty JSONSchemer.schema(schema).validate(bundle).to_a
  end
end

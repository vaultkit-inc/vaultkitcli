# frozen_string_literal: true

# Run with: ruby -Ilib test/policy_bundle_command_test.rb
require "minitest/autorun"
require "tmpdir"
require "yaml"
require "json"
require_relative "../lib/vkit/cli"
require_relative "../lib/vkit/cli/commands/base_command"
require_relative "../lib/vkit/cli/commands/policy_bundle_command"
require_relative "../lib/vkit/cli/commands/policy_deploy_command"
require_relative "../lib/vkit/cli/commands/policy_validate_command"
require_relative "../lib/vkit/cli/policy_pack/manager"

# `vkit policy bundle`, `validate` and `deploy` in a repo with all three packs
# and one repo policy.
class PolicyBundleCommandTest < Minitest::Test
  PACKS = %w[starter ai_safety financial_compliance].freeze

  FakeStore = Struct.new(:user) do
    def logged_in? = true
  end

  # Fails the first post with `fail_first`, then returns `response`.
  class FakeClient
    attr_reader :posts

    def initialize(fail_first: nil)
      @fail_first = fail_first
      @posts = []
    end

    def post(path, body:)
      @posts << [path, body]
      if @fail_first
        error, @fail_first = @fail_first, nil
        raise error
      end
      { "bundle_version" => body[:bundle].dig("bundle", "bundle_version"), "state" => "active" }
    end
  end

  def setup
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, ".vkit"))
    FileUtils.mkdir_p(File.join(@dir, "datasets"))
    File.write(File.join(@dir, "datasets", "registry.yaml"), {
      "customers" => {
        "datasource" => "main",
        "fields" => {
          "email" => { "type" => "text", "sensitivity" => "medium", "category" => "pii" },
          "password_hash" => { "type" => "text", "sensitivity" => "critical", "category" => "credential" },
          "card_last4" => { "type" => "text", "sensitivity" => "high", "category" => "financial" },
          "notes" => { "type" => "text", "sensitivity" => "unknown", "category" => "unknown" }
        }
      }
    }.to_yaml)
    manager = Vkit::CLI::PolicyPack::Manager.new(project_root: @dir)
    PACKS.each { |pack| manager.install!(pack) }
    File.write(File.join(@dir, "config", "policies", "allow_support_reads.yaml"), {
      "id" => "allow_support_reads", "description" => "Support may read customers.",
      "match" => { "dataset" => "customers" }, "action" => { "allow" => true }
    }.to_yaml)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def wire(command, client = nil)
    store = FakeStore.new({ "organization_slug" => "acme" })
    command.define_singleton_method(:credential_store) { store }
    command.define_singleton_method(:authenticated_client) { client }
    command
  end

  # [stdout, exit status or nil]
  def run_command
    status = nil
    out, = capture_io do
      Dir.chdir(@dir) { yield }
    rescue SystemExit => e
      status = e.status
    end
    [out, status]
  end

  def bundle
    run_command do
      wire(Vkit::CLI::Commands::PolicyBundleCommand.new).call(
        policies_dir: "config/policies", registry_dir: "datasets", out: "dist/policy_bundle.json",
        org: nil, version: "abc1234"
      )
    end
  end

  def deploy(client)
    run_command do
      wire(Vkit::CLI::Commands::PolicyDeployCommand.new, client).call(
        bundle_path: "dist/policy_bundle.json", org: nil, activate: true
      )
    end
  end

  def bundle_json
    JSON.parse(File.read(File.join(@dir, "dist", "policy_bundle.json")))
  end

  def write_bundle(bundle)
    File.write(File.join(@dir, "dist", "policy_bundle.json"), JSON.generate(bundle))
  end

  def test_bundle_prints_how_many_policies_each_pack_and_the_repo_contribute
    out, status = bundle

    assert_nil status
    assert_includes out, "✅ Policy bundle created"
    assert_includes out, "Policies: 12"
    assert_match(/starter 2\.0\.0\s+6$/, out)
    assert_match(/ai_safety 2\.0\.0\s+3$/, out)
    assert_match(/financial_compliance 2\.0\.0\s+2$/, out)
    assert_match(%r{repo \(config/policies\)\s+1$}, out)
  end

  def test_bundle_exits_1_and_writes_nothing_when_a_pack_file_is_missing
    File.delete(Dir[File.join(@dir, "config", "policies", "starter__01__*.yaml")].first)

    out, status = bundle

    assert_equal 1, status
    assert_includes out, "starter 2.0.0:"
    assert_includes out, "missing config/policies/starter__01__deny_credentials.yaml (deny_credentials)"
    refute_includes out, "Policy bundle created"
    refute File.exist?(File.join(@dir, "dist", "policy_bundle.json"))
  end

  def test_deploy_sends_a_complete_bundle
    bundle
    client = FakeClient.new

    out, status = deploy(client)

    assert_nil status
    assert_includes out, "Policy bundle deployed"
    starter = client.posts.last[1][:bundle].dig("bundle", "installed_packs").find { |p| p["name"] == "starter" }
    assert_includes starter["policy_ids"], "deny_credentials"
  end

  def test_deploy_refuses_a_bundle_missing_a_pack_policy
    bundle
    b = bundle_json
    b["policies"].reject! { |p| p["id"] == "mask_pii_by_default" }
    write_bundle(b)
    client = FakeClient.new

    out, status = deploy(client)

    assert_equal 1, status
    assert_includes out, "missing policies: mask_pii_by_default"
    assert_empty client.posts
  end

  def test_deploy_refuses_an_old_format_bundle_missing_a_pack_policy
    bundle
    b = bundle_json
    b["policies"].reject! { |p| p["id"] == "deny_credentials" }
    b["bundle"]["installed_packs"].each { |p| p.delete("policy_ids") }
    write_bundle(b)

    out, status = deploy(FakeClient.new)

    assert_equal 1, status
    assert_includes out, "missing policies: deny_credentials"
  end

  def test_deploy_retries_without_policy_ids_for_an_older_control_plane
    bundle
    schema_error = Vkit::CLI::API::APIError.new(
      422, 'Schema errors: [{"data_pointer"=>"/bundle/installed_packs/0/policy_ids", "type"=>"schema"}]'
    )
    client = FakeClient.new(fail_first: schema_error)

    out, status = deploy(client)

    assert_nil status
    assert_includes out, "Policy bundle deployed"
    assert_equal 2, client.posts.length
    retried = client.posts.last[1][:bundle]
    assert(retried.dig("bundle", "installed_packs").none? { |p| p.key?("policy_ids") })
    copy = JSON.parse(JSON.generate(retried))
    copy["bundle"]["checksum"] = ""
    assert_equal Digest::SHA256.hexdigest(Vkit::Policy::BundleCompiler.canonical_json(copy)),
                 retried.dig("bundle", "checksum")
  end

  def test_deploy_does_not_retry_other_errors
    bundle
    client = FakeClient.new(fail_first: Vkit::CLI::API::APIError.new(422, "Checksum mismatch"))

    assert_raises(Vkit::CLI::API::APIError) { deploy(client) }
    assert_equal 1, client.posts.length
  end

  def test_validate_fails_on_a_bundle_missing_a_pack_policy
    bundle
    b = bundle_json
    b["policies"].reject! { |p| p["id"] == "deny_credentials" }
    write_bundle(b)

    out, status = run_command do
      Vkit::CLI::Commands::PolicyValidateCommand.new.call(bundle_path: "dist/policy_bundle.json", schema_path: nil)
    end

    assert_equal 1, status
    assert_includes out, "missing policies: deny_credentials"
  end
end

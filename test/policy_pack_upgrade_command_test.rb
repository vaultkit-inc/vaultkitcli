# frozen_string_literal: true

# Run with: ruby -Ilib test/policy_pack_upgrade_command_test.rb
require "minitest/autorun"
require "tmpdir"
require "yaml"
require "stringio"
require_relative "../lib/vkit/cli/commands/base_command"
require_relative "../lib/vkit/policy/policy_validator"
require_relative "../lib/vkit/cli/policy_pack/manager"
require_relative "../lib/vkit/cli/commands/policy_pack_upgrade_command"
require_relative "support/shipped_packs"

class PolicyPackUpgradeCommandTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, ".vkit"))
    Vkit::CLI::PolicyPack::Manager.new(project_root: @dir).install!("starter")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def upgrade(pack_name: nil, **options)
    out, = run_upgrade(pack_name: pack_name, **options)
    out
  end

  # [stdout, exit status or nil]
  def run_upgrade(pack_name: nil, **options)
    status = nil
    out, = capture_io do
      Vkit::CLI::Commands::PolicyPackUpgradeCommand.new.call(pack_name: pack_name, dir: @dir, **options)
    rescue SystemExit => e
      status = e.status
    end
    [out, status]
  end

  # A terminal that answers `answer`.
  def terminal(answer)
    input = StringIO.new("#{answer}\n")
    input.define_singleton_method(:tty?) { true }
    input
  end

  def deny_credentials_path
    File.join(@dir, "config", "policies", "starter__01__deny_credentials.yaml")
  end

  def set_installed_version(pack, version)
    path = File.join(@dir, ".vkit", "packs.yaml")
    state = YAML.safe_load(File.read(path))
    state["installed_packs"][pack]["version"] = version
    File.write(path, state.to_yaml)
  end

  def test_upgrade_all_reports_packs_that_are_up_to_date
    out = upgrade

    assert_includes out, "✓ starter is already up to date"
    refute_includes out, "Error"
  end

  def test_upgrade_all_upgrades_an_outdated_pack
    set_installed_version("starter", "0.0.1")

    out = upgrade

    assert_includes out, "✅ starter"
    assert_includes out, "From: v0.0.1"
    refute_includes out, "Error"
  end

  def test_upgrade_single_pack_still_works
    assert_includes upgrade(pack_name: "starter"), "✓ starter is already up to date"
  end

  def test_missing_files_are_not_reported_as_up_to_date
    File.delete(deny_credentials_path)

    out, status = run_upgrade(pack_name: "starter", input: StringIO.new)

    assert_equal 1, status
    refute_includes out, "already up to date"
    assert_includes out, "starter #{ShippedPacks.version("starter")} is installed, but 1 of its files are missing"
    assert_includes out, "config/policies/starter__01__deny_credentials.yaml (deny_credentials)"
    assert_includes out, "--restore"
    refute File.exist?(deny_credentials_path)
  end

  def test_restore_rewrites_only_the_missing_files
    mask = File.join(@dir, "config", "policies", "starter__02__mask_pii_by_default.yaml")
    File.write(mask, File.read(mask) + "# my edit\n")
    File.delete(deny_credentials_path)

    out, status = run_upgrade(pack_name: "starter", restore: true)

    assert_nil status
    assert_includes out, "✅ starter: restored 1 missing file(s) at v#{ShippedPacks.version("starter")}"
    assert_includes File.read(deny_credentials_path), "id: deny_credentials"
    assert_includes File.read(deny_credentials_path), "# Pack Version: #{ShippedPacks.version("starter")}"
    assert_includes File.read(mask), "# my edit"
  end

  def test_a_terminal_is_offered_the_restore
    File.delete(deny_credentials_path)

    out, status = run_upgrade(input: terminal("y"))

    assert_nil status
    assert_includes out, "Restore them from the pack? [Y/n]"
    assert File.exist?(deny_credentials_path)
  end

  def test_declining_the_restore_exits_1
    File.delete(deny_credentials_path)

    _, status = run_upgrade(input: terminal("n"))

    assert_equal 1, status
    refute File.exist?(deny_credentials_path)
  end

  def test_an_upgrade_tolerates_missing_files_of_the_old_version
    set_installed_version("starter", "0.0.1")
    File.delete(deny_credentials_path)

    out, status = run_upgrade(pack_name: "starter")

    assert_nil status
    assert_includes out, "✅ starter"
    assert File.exist?(deny_credentials_path)
  end

  def test_a_failed_upgrade_exits_1
    _, status = run_upgrade(pack_name: "no_such_pack")

    assert_equal 1, status
  end
end

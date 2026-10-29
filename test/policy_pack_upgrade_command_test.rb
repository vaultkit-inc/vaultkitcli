# frozen_string_literal: true

# Run with: ruby -Ilib test/policy_pack_upgrade_command_test.rb
require "minitest/autorun"
require "tmpdir"
require "yaml"
require_relative "../lib/vkit/cli/commands/base_command"
require_relative "../lib/vkit/policy/policy_validator"
require_relative "../lib/vkit/cli/policy_pack/manager"
require_relative "../lib/vkit/cli/commands/policy_pack_upgrade_command"

class PolicyPackUpgradeCommandTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, ".vkit"))
    Vkit::CLI::PolicyPack::Manager.new(project_root: @dir).install!("starter")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def upgrade(pack_name: nil)
    out, = capture_io do
      Vkit::CLI::Commands::PolicyPackUpgradeCommand.new.call(pack_name: pack_name, dir: @dir)
    end
    out
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
end

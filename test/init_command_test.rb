# frozen_string_literal: true

# Run with: ruby -Ilib test/init_command_test.rb
require "minitest/autorun"
require "tmpdir"
require "json"
require "open3"
require_relative "../lib/vkit/cli"
require_relative "../lib/vkit/cli/commands/base_command"
require_relative "../lib/vkit/cli/commands/init_command"
require_relative "../lib/vkit/cli/commands/policy_bundle_command"

class InitCommandTest < Minitest::Test
  GIT_ENV = { "GIT_AUTHOR_NAME" => "Test", "GIT_AUTHOR_EMAIL" => "test@example.test",
              "GIT_COMMITTER_NAME" => "Test", "GIT_COMMITTER_EMAIL" => "test@example.test" }.freeze

  FakeStore = Struct.new(:user) do
    def logged_in? = true
  end

  def setup
    @root = Dir.mktmpdir
    @dir = File.join(@root, "policies")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def init(dir: @dir, git: true)
    out, = capture_io { Vkit::CLI::Commands::InitCommand.new.call(dir: dir, packs: nil, git: git) }
    out
  end

  def git(dir, *args)
    out, status = Open3.capture2e(GIT_ENV, "git", *args, chdir: dir)
    assert status.success?, "git #{args.join(' ')}: #{out}"
    out
  end

  def test_runs_git_init_and_says_so_without_committing
    out = init

    assert File.directory?(File.join(@dir, ".git"))
    assert_includes out, "Initialized a git repository in #{@dir}"
    assert_includes out, "git add -A && git commit"
    assert_equal "", `git -C #{@dir} log --oneline 2>/dev/null`
  end

  def test_no_git_skips_it
    out = init(git: false)

    refute File.exist?(File.join(@dir, ".git"))
    refute_includes out, "Initialized a git repository"
  end

  def test_leaves_an_existing_repository_alone
    git(@root, "init", "-q")

    out = init

    refute File.exist?(File.join(@dir, ".git"))
    refute_includes out, "Initialized a git repository"
  end

  def ignored?(path)
    system("git", "check-ignore", "-q", path, chdir: @dir)
  end

  def test_gitignore_tracks_packs_yaml_and_ignores_the_rest_of_vkit
    init

    refute ignored?(".vkit/packs.yaml")
    assert ignored?(".vkit/scratch.tmp")
    assert ignored?("dist/policy_bundle.json")
    refute ignored?("config/policies/starter__01__deny_credentials.yaml")
  end

  # The pack integrity check reads .vkit/packs.yaml. When .gitignore hid it, a
  # fresh clone had no record, so a deleted pack policy went unnoticed.
  def test_a_fresh_clone_still_runs_the_pack_integrity_check
    init
    git(@dir, "add", "-A")
    git(@dir, "commit", "-q", "-m", "Policies")
    clone = File.join(@root, "clone")
    git(@root, "clone", "-q", @dir, clone)
    assert File.exist?(File.join(clone, ".vkit", "packs.yaml")), "packs.yaml is committed"

    File.delete(Dir[File.join(clone, "config", "policies", "starter__01__*.yaml")].first)
    git(clone, "commit", "-q", "-am", "Drop a pack policy")
    out, status = bundle_in(clone)

    assert_equal 1, status
    assert_includes out, "missing config/policies/starter__01__deny_credentials.yaml"
  end

  def bundle_in(dir)
    command = Vkit::CLI::Commands::PolicyBundleCommand.new
    store = FakeStore.new({ "organization_slug" => "acme" })
    command.define_singleton_method(:credential_store) { store }
    status = nil
    out, = capture_io do
      Dir.chdir(dir) do
        command.call(policies_dir: "config/policies", registry_dir: "datasets", out: "dist/policy_bundle.json",
                     org: nil, version: nil)
      end
    rescue SystemExit => e
      status = e.status
    end
    [out, status]
  end
end

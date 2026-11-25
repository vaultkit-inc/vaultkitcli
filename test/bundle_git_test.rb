# frozen_string_literal: true

# Run with: ruby -Ilib test/bundle_git_test.rb
require "minitest/autorun"
require "tmpdir"
require "yaml"
require "json"
require_relative "../lib/vkit/cli"
require_relative "../lib/vkit/cli/commands/base_command"
require_relative "../lib/vkit/cli/commands/policy_bundle_command"
require "json_schemer"
require_relative "../lib/vkit/cli/policy_pack/manager"

# How `vkit policy bundle` gets a bundle's version and source from git: it
# refuses to bundle what can't be traced to a commit, unless told to.
class BundleGitTest < Minitest::Test
  GIT_ENV = { "GIT_AUTHOR_NAME" => "Test", "GIT_AUTHOR_EMAIL" => "test@example.test",
              "GIT_COMMITTER_NAME" => "Test", "GIT_COMMITTER_EMAIL" => "test@example.test" }.freeze

  FakeStore = Struct.new(:user) do
    def logged_in? = true
  end

  def setup
    @dir = @root = Dir.mktmpdir
    FileUtils.mkdir_p(File.join(@dir, "datasets"))
    File.write(File.join(@dir, "datasets", "registry.yaml"), {
      "customers" => {
        "datasource" => "main",
        "fields" => { "email" => { "type" => "text", "sensitivity" => "medium", "category" => "pii" } }
      }
    }.to_yaml)
    Vkit::CLI::PolicyPack::Manager.new(project_root: @dir).install!("starter")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def git(*args)
    system(GIT_ENV, "git", *args, chdir: @dir, out: File::NULL, err: File::NULL) or flunk "git #{args.join(' ')} failed"
  end

  def commit_all
    git("init", "-q", "-b", "main")
    git("add", "-A")
    git("commit", "-q", "-m", "Policies")
  end

  def head
    `git -C #{@dir} rev-parse HEAD`.strip
  end

  # [stdout, exit status or nil]
  def bundle(version: nil, allow_dirty: false)
    command = Vkit::CLI::Commands::PolicyBundleCommand.new
    store = FakeStore.new({ "organization_slug" => "acme" })
    command.define_singleton_method(:credential_store) { store }
    status = nil
    out, = capture_io do
      Dir.chdir(@dir) do
        command.call(policies_dir: "config/policies", registry_dir: "datasets", out: "dist/policy_bundle.json",
                     org: nil, version: version, allow_dirty: allow_dirty)
      end
    rescue SystemExit => e
      status = e.status
    end
    [out, status]
  end

  def written
    path = File.join(@dir, "dist", "policy_bundle.json")
    File.exist?(path) ? JSON.parse(File.read(path)) : nil
  end

  SCHEMA = File.expand_path("../lib/vkit/policy/schema/policy_bundle.schema.json", __dir__)

  # Against the bundle schema vkit ships; the errors, or [] when valid.
  def schema_errors(bundle)
    JSONSchemer.schema(JSON.parse(File.read(SCHEMA))).validate(bundle).map { |e| e["error"] }
  end

  def assert_valid(bundle)
    assert_equal [], schema_errors(bundle)
  end

  def edit_policy
    path = Dir[File.join(@dir, "config", "policies", "starter__01__*.yaml")].first
    File.write(path, File.read(path) + "# edited\n")
    path
  end

  def test_a_clean_repo_is_versioned_by_its_commit
    commit_all

    out, status = bundle

    assert_nil status, out
    source = written["bundle"]["source"]
    assert_equal head, written["bundle"]["bundle_version"]
    assert_equal head, source["commit_sha"]
    assert_equal "main", source["ref"]
    refute source.key?("dirty")
    assert_valid(written)
  end

  # Before, this bundled silently under HEAD's commit, which doesn't contain
  # the edit.
  def test_an_uncommitted_change_is_refused
    commit_all
    edit_policy

    out, status = bundle

    assert_equal 1, status
    assert_includes out, "Code: bundle_not_committed"
    assert_includes out, "config/policies/starter__01__deny_credentials.yaml"
    assert_includes out, "git add -A -- config/policies datasets .vkit/packs.yaml"
    assert_includes out, "git commit -m"
    assert_includes out, "--allow-dirty"
    assert_nil written
  end

  def test_an_untracked_policy_and_a_registry_change_are_refused
    commit_all
    File.write(File.join(@dir, "config", "policies", "new_policy.yaml"), { "id" => "x" }.to_yaml)
    File.write(File.join(@dir, "datasets", "registry.yaml"), "{}\n")

    out, status = bundle

    assert_equal 1, status
    assert_includes out, "config/policies/new_policy.yaml"
    assert_includes out, "datasets/registry.yaml"
  end

  def test_a_staged_but_uncommitted_change_is_refused
    commit_all
    git("add", edit_policy)

    _, status = bundle

    assert_equal 1, status
  end

  def test_changes_outside_the_policy_inputs_dont_count
    commit_all
    File.write(File.join(@dir, "README.md"), "notes\n")
    FileUtils.mkdir_p(File.join(@dir, "dist"))
    File.write(File.join(@dir, "dist", "old.json"), "{}")

    out, status = bundle

    assert_nil status, out
  end

  # Projects from vkit init before this release ignored all of .vkit/.
  def test_an_ignored_packs_yaml_is_refused_with_how_to_track_it
    File.write(File.join(@dir, ".gitignore"), "dist/\n.vkit/\n")
    commit_all

    out, status = bundle

    assert_equal 1, status
    assert_includes out, ".vkit/packs.yaml (ignored by .gitignore)"
    assert_includes out, "git add -f -- .vkit/packs.yaml"
    assert_includes out, "replace .vkit/ with two lines"
  end

  def test_allow_dirty_bundles_and_records_it
    commit_all
    edit_policy

    out, status = bundle(allow_dirty: true)

    assert_nil status, out
    assert_includes out, "Bundling uncommitted changes (--allow-dirty)"
    assert_includes out, "config/policies/starter__01__deny_credentials.yaml"
    source = written["bundle"]["source"]
    assert_equal true, source["dirty"]
    assert_equal head, source["commit_sha"]
    assert_valid(written)
  end

  def test_no_repo_and_no_version_is_refused_before_anything_is_written
    out, status = bundle

    assert_equal 1, status
    assert_includes out, "Code: bundle_not_versioned"
    assert_includes out, "git init"
    assert_includes out, "--version"
    assert_nil written
  end

  def test_a_repo_with_no_commits_and_no_version_is_refused
    git("init", "-q", "-b", "main")

    out, status = bundle

    assert_equal 1, status
    assert_includes out, "Code: bundle_not_versioned"
  end

  def test_version_without_a_repo_names_the_bundle_and_records_no_commit
    out, status = bundle(version: "v1.2")

    assert_nil status, out
    assert_equal "v1.2", written["bundle"]["bundle_version"]
    refute written["bundle"]["source"].key?("commit_sha")
    assert_valid(written)
  end

  def test_version_in_a_repo_keeps_the_real_commit
    commit_all

    out, status = bundle(version: "v1.2")

    assert_nil status, out
    assert_equal "v1.2", written["bundle"]["bundle_version"]
    assert_equal head, written["bundle"]["source"]["commit_sha"]
    assert_valid(written)
  end

  def test_version_does_not_skip_the_uncommitted_check
    commit_all
    edit_policy

    out, status = bundle(version: "v1.2")

    assert_equal 1, status
    assert_includes out, "Code: bundle_not_committed"
  end

  def test_a_policy_project_in_a_subfolder_reports_its_own_paths
    project = File.join(@dir, "policies-repo")
    FileUtils.mkdir_p(project)
    FileUtils.mv(Dir.glob(File.join(@dir, "{config,datasets,.vkit}"), File::FNM_DOTMATCH), project)
    commit_all
    path = Dir[File.join(project, "config", "policies", "starter__01__*.yaml")].first
    assert path, "the project moved into the subfolder"
    File.write(path, File.read(path) + "# edited\n")
    @dir = project

    out, status = bundle

    assert_equal 1, status
    assert_includes out, "   config/policies/starter__01__deny_credentials.yaml"
  end

  def test_errors_carry_a_code_and_fix_for_scripts
    error = Vkit::CLI::CommandError.new("Nope", code: "bundle_not_versioned", fix: ["git init"])

    assert_equal({ "status" => "error", "code" => "bundle_not_versioned", "error" => "Nope", "fix" => ["git init"] },
                 error.to_h)
  end
end

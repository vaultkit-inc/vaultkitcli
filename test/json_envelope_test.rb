# frozen_string_literal: true

# Run with: ruby -Ilib test/json_envelope_test.rb
#
# --format json, as an agent sees it: one envelope on stdout, logs on
# stderr, exit 0 / 1 / 3, prompts turned into needs_input, setup steps safe
# to rerun, and no secret in any output.
require "minitest/autorun"
require "yaml"
require "tmpdir"
require "fileutils"
require "open3"
require "digest"
require_relative "support/envelope"

# Swaps the control plane and the saved login for fakes, only while a test
# has set FakeBackend.client (other test files see the real methods).
module FakeBackend
  class << self
    attr_accessor :client, :store
  end

  def credential_store
    FakeBackend.store || super
  end

  def authenticated_client
    return super unless FakeBackend.client

    Vkit::CLI::Output.register_secret(FakeBackend.store&.token)
    FakeBackend.client
  end
end
Vkit::CLI::Commands::BaseCommand.prepend(FakeBackend)

class FakeStore
  attr_reader :user, :token, :endpoint

  def initialize(user: { "email" => "a@x.test", "role" => "admin", "organization_slug" => "acme" },
                 token: "tok_session_secret_123456", endpoint: "http://cp.test")
    @user = user
    @token = token
    @endpoint = endpoint
  end

  def logged_in?
    !!(token && endpoint)
  end
end

# Answers get/post by path: a value, an exception to raise, or a proc.
class FakeClient
  attr_reader :calls

  def initialize(routes = {})
    @routes = routes
    @calls = []
  end

  def get(path, params: {})
    answer(:get, path, nil)
  end

  def post(path, body:)
    answer(:post, path, body)
  end

  private

  def answer(verb, path, body)
    @calls << [verb, path, body]
    value = @routes.fetch([verb, path]) { raise "unexpected #{verb} #{path}" }
    value = value.call(body) if value.respond_to?(:call)
    raise value if value.is_a?(Exception)

    value
  end
end

module JsonTestHelpers
  include EnvelopeHelper

  # Replaces obj.name with impl (a proc) for the block.
  def stubbing(obj, name, impl)
    singleton = obj.singleton_class
    had_own = singleton.instance_methods(false).include?(name) || singleton.private_instance_methods(false).include?(name)
    original = obj.method(name) if had_own
    singleton.send(:define_method, name) { |*args, **kw, &blk| kw.empty? ? impl.call(*args, &blk) : impl.call(*args, **kw, &blk) }
    yield
  ensure
    if had_own
      singleton.send(:define_method, name, original)
    else
      singleton.send(:remove_method, name)
    end
  end

  SECRET = "s3cr3t-db-passw0rd"
  DS = "/api/v1/orgs/acme/datasources"

  def setup
    FakeBackend.store = FakeStore.new
    FakeBackend.client = nil
    @saved_env = ENV.to_h
  end

  def teardown
    FakeBackend.store = nil
    FakeBackend.client = nil
    ENV.replace(@saved_env)
  end

  # argv through Thor, as `vkit ... --format json` runs it.
  def cli(*argv)
    out, code, err = run_cli(*argv, "--format", "json")
    lines = out.lines
    assert_equal 1, lines.length, "stdout must be exactly one JSON object:\n#{out}"
    [JSON.parse(lines.first), code, err, out]
  end

  def refute_leaks(*outputs, secrets: [SECRET, FakeStore.new.token])
    outputs.each do |o|
      secrets.each { |s| refute_includes o, s }
    end
  end

  def not_found
    Vkit::CLI::API::APIError.new(404, "Not Found")
  end

  def ds_add(*extra)
    cli("datasource", "add", "--id", "shop", "--engine", "postgres", "--username", "app",
        "--config", '{"host":"db","port":5432}', "--region", "us", "--environment", "production", *extra)
  end
end

class EnvelopeShapeTest < Minitest::Test
  include JsonTestHelpers

  def test_ok_envelope_has_status_result_and_next_and_logs_go_to_stderr
    envelope, code, err = run_json do
      puts "progress line"
      Vkit::CLI::Output.respond(result: { "a" => 1 }, next_steps: ["vkit next"])
    end

    assert_equal 0, code
    assert_equal({ "status" => "ok", "result" => { "a" => 1 }, "next" => ["vkit next"] }, envelope)
    assert_includes err, "progress line"
  end

  def test_errors_carry_a_code_a_message_and_a_one_sentence_fix
    envelope, code, = run_json { raise Vkit::CLI::CommandError.new("boom", code: "x_failed", fix: ["do a", "or b"]) }

    assert_equal 1, code
    assert_equal "error", envelope["status"]
    assert_equal({ "code" => "x_failed", "message" => "boom", "fix" => "do a; or b" }, envelope["error"])
  end

  def test_needs_input_has_its_own_exit_code
    envelope, code, = run_json { raise Vkit::CLI::NeedsInput.new("?", code: "secret_required", fix: ["ask"]) }

    assert_equal Vkit::CLI::Output::EXIT_NEEDS_INPUT, code
    refute_equal 0, code
    refute_equal 1, code
    assert_equal "needs_input", envelope["status"]
  end

  def test_thor_argument_errors_are_envelopes_too
    envelope, code, = cli("datasource", "add", "--id", "x")

    assert_equal 1, code
    assert_equal "invalid_arguments", envelope.dig("error", "code")
  end

  def test_registered_secrets_are_scrubbed_from_the_envelope
    envelope, = run_json do
      Vkit::CLI::Output.register_secret(SECRET)
      raise "connection failed with password #{SECRET}"
    end

    refute_includes JSON.generate(envelope), SECRET
    assert_includes envelope.dig("error", "message"), "[REDACTED]"
  end

  def test_json_is_detected_before_thor_parses
    assert Vkit::CLI::Output.json_requested?(%w[scan shop --format json])
    assert Vkit::CLI::Output.json_requested?(%w[scan shop --format=json])
    refute Vkit::CLI::Output.json_requested?(%w[scan shop --format human])
    refute Vkit::CLI::Output.json_requested?(%w[request -- --format json])
  end

  def test_the_real_binary_prints_one_object_and_exits_3_for_needs_input
    out, err, status = Open3.capture3({ "HOME" => Dir.mktmpdir }, "ruby", "bin/vkit", "reset", "--format", "json",
                                      stdin_data: "y\n", chdir: File.expand_path("..", __dir__))

    assert_equal 3, status.exitstatus, err
    assert_equal 1, out.lines.length
    assert_equal "confirmation_required", JSON.parse(out).dig("error", "code")
  end

  def test_version
    out, _err, status = Open3.capture3("ruby", "bin/vkit", "--version", "--format", "json",
                                       chdir: File.expand_path("..", __dir__))

    assert status.success?
    assert_equal Vkit::VERSION, JSON.parse(out).dig("result", "version")
  end
end

class ErrorCodeTest < Minitest::Test
  include JsonTestHelpers

  def code_for(error)
    envelope, = run_json { raise error }
    envelope.dig("error", "code")
  end

  def test_not_logged_in
    FakeBackend.store = FakeStore.new(token: nil)

    envelope, = cli("scan", "shop")
    assert_equal "not_logged_in", envelope.dig("error", "code")
    assert_includes envelope.dig("error", "fix"), "vkit login"
  end

  def test_session_expired_for_a_persons_login_and_an_agent_token
    assert_equal "session_expired", code_for(Vkit::CLI::API::APIError.new(401, "Signature has expired"))
    assert_equal "session_expired", code_for(Vkit::CLI::API::APIError.new(401, "Agent token x expired", code: "token_expired"))
    assert_equal "token_revoked", code_for(Vkit::CLI::API::APIError.new(401, "revoked token"))
    assert_equal "not_authenticated", code_for(Vkit::CLI::API::APIError.new(401, "Missing credentials"))
  end

  def test_whoamis_login_check_is_mapped_too
    assert_equal "session_expired",
                 code_for(Vkit::Core::AuthClient::HTTPError.new(401, '{"error":"Signature has expired"}'))
  end

  def test_control_plane_unreachable
    assert_equal "control_plane_unreachable", code_for(Errno::ECONNREFUSED.new("connect(2)"))
    assert_equal "control_plane_unreachable", code_for(SocketError.new("getaddrinfo"))
  end

  def test_datasource_connection_errors_from_a_scan
    refused = "Funl error 502 (datasource_unavailable): Couldn't reach the datasource. Try again, or ask an admin to check it."
    auth = "Funl error 502 (datasource_unavailable): Couldn't connect to the datasource. Ask an admin to check it."

    assert_equal "datasource_unreachable", code_for(Vkit::CLI::API::APIError.new(422, refused))
    assert_equal "datasource_connection_failed", code_for(Vkit::CLI::API::APIError.new(422, auth))
    assert_equal "query_runtime_unavailable",
                 code_for(Vkit::CLI::API::APIError.new(422, "Failed to open TCP connection to funl:8080"))
  end

  def test_unknown_pack_lists_the_packs
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, ".vkit"))
      envelope, code, = cli("policy", "pack", "add", "nope", "--dir", dir)

      assert_equal 1, code
      assert_equal "unknown_pack", envelope.dig("error", "code")
      assert_includes envelope.dig("result", "available_packs"), "starter"
    end
  end
end

class SecretInputTest < Minitest::Test
  include JsonTestHelpers

  REAL_FROM_TTY = Vkit::CLI::SecretInput.method(:from_tty)

  def created_body(client)
    client.calls.find { |verb, path, _| verb == :post && path == DS }&.last
  end

  def new_ds_client
    FakeClient.new([:get, "#{DS}/shop"] => not_found,
                   [:post, DS] => ->(body) { { "name" => body[:name], "engine" => body[:engine], "config" => body[:config] } })
  end

  def test_no_password_source_is_needs_input_telling_the_agent_to_hand_over
    FakeBackend.client = new_ds_client

    envelope, code, = ds_add

    assert_equal 3, code
    assert_equal "needs_input", envelope["status"]
    assert_equal "secret_required", envelope.dig("error", "code")
    assert_includes envelope.dig("error", "fix"), "--password-prompt"
    assert_nil created_body(FakeBackend.client)
  end

  def test_password_env_sends_the_password_and_never_prints_it
    ENV["SHOP_PW"] = SECRET
    FakeBackend.client = new_ds_client

    envelope, code, err, out = ds_add("--password-env", "SHOP_PW")

    assert_equal 0, code, out
    assert_equal false, envelope.dig("result", "already_existed")
    assert_equal SECRET, created_body(FakeBackend.client)[:password]
    assert_equal "US", created_body(FakeBackend.client)[:region]
    refute_leaks(out, err)
  end

  def test_an_unset_env_var_is_named_not_shown
    FakeBackend.client = new_ds_client

    envelope, code, = ds_add("--password-env", "NOT_SET_ANYWHERE")

    assert_equal 1, code
    assert_equal "secret_env_missing", envelope.dig("error", "code")
    assert_includes envelope.dig("error", "message"), "NOT_SET_ANYWHERE"
  end

  def test_password_flag_still_works_with_a_deprecation_warning_and_isnt_echoed
    FakeBackend.client = new_ds_client

    envelope, code, err, out = ds_add("--password", SECRET)

    assert_equal 0, code
    assert_equal "ok", envelope["status"]
    assert_includes err, "--password is deprecated"
    refute_leaks(out, err)
  end

  def test_password_flag_in_human_mode_warns_on_stderr_and_prints_redacted
    FakeBackend.client = new_ds_client

    out, err = capture_io do
      Vkit::CLI::BaseCLI.start(%w[datasource add --id shop --engine postgres --username app --config {}
                                  --region us --environment production --password] + [SECRET])
    end

    assert_includes err, "--password is deprecated"
    assert_includes out, "✅ Datasource created:"
    assert_includes out, "[REDACTED]"
    refute_leaks(out, err)
  end

  def test_password_prompt_without_a_terminal_is_needs_input
    FakeBackend.client = new_ds_client
    stubbing(Vkit::CLI::SecretInput, :from_tty, ->(*) { REAL_FROM_TTY.call("x", tty_path: "/nonexistent/tty") }) do
      envelope, code, = ds_add("--password-prompt")

      assert_equal 3, code
      assert_equal "secret_required", envelope.dig("error", "code")
    end
  end

  def test_password_prompt_takes_the_password_from_the_terminal_not_stdin
    FakeBackend.client = new_ds_client
    stubbing(Vkit::CLI::SecretInput, :from_tty, ->(_label) { SECRET }) do
      stubbing($stdin, :gets, -> { flunk "read stdin" }) do
        _envelope, code, err, out = ds_add("--password-prompt")

        assert_equal 0, code
        assert_equal SECRET, created_body(FakeBackend.client)[:password]
        refute_leaks(out, err)
      end
    end
  end

  # A real terminal: the prompt and the typing stay on it, with echo off.
  def test_from_tty_reads_a_terminal_with_echo_off
    require "pty"
    require "io/wait"
    require "timeout"
    Timeout.timeout(5) { PTY.open do |master, slave|
      reader = Thread.new { Vkit::CLI::SecretInput.from_tty("Password", tty_path: slave.path) }
      sleep 0.05 until master.wait_readable(0.05) && (prompt = master.readpartial(100)).include?("Password")
      master.write("#{SECRET}\n")

      assert_equal SECRET, reader.value
      assert_includes prompt, "Password: "
      echoed = master.wait_readable(0.2) ? master.readpartial(100) : ""
      refute_includes echoed, SECRET
    end }
  end

  def test_two_password_sources_is_an_error
    ENV["SHOP_PW"] = SECRET
    FakeBackend.client = new_ds_client

    envelope, code, = ds_add("--password-env", "SHOP_PW", "--password-prompt")

    assert_equal 1, code
    assert_equal "conflicting_password_sources", envelope.dig("error", "code")
  end
end

class IdempotencyTest < Minitest::Test
  include JsonTestHelpers

  EXISTING = { "name" => "shop", "engine" => "postgres", "config" => {} }.freeze

  # A control plane from before vaultkit#126 refuses the duplicate name.
  def existing_client(post: Vkit::CLI::API::APIError.new(422, "Name has already been taken"))
    FakeClient.new([:get, "#{DS}/shop"] => EXISTING, [:post, DS] => post)
  end

  def test_datasource_add_for_an_existing_id_changes_nothing
    FakeBackend.client = existing_client

    envelope, code, = ds_add

    assert_equal 0, code
    assert_equal true, envelope.dig("result", "already_existed")
    assert_equal false, envelope.dig("result", "credential_updated")
    posted = FakeBackend.client.calls.select { |verb, _, _| verb == :post }.map(&:last)
    assert(posted.all? { |body| !body.key?(:password) }, "no credential is sent for an existing id")
  end

  def test_the_same_settings_again_is_already_existed_from_the_control_plane
    FakeBackend.client = existing_client(post: EXISTING.merge("already_existed" => true, "credential_updated" => false))

    envelope, code, = ds_add

    assert_equal 0, code
    assert_equal true, envelope.dig("result", "already_existed")
  end

  def test_different_settings_are_datasource_exists_with_a_fix
    conflict = Vkit::CLI::API::APIError.from_body(409, { "error" => "Datasource shop already exists with different settings.",
                                                        "code" => "datasource_exists" })
    FakeBackend.client = existing_client(post: conflict)

    envelope, code, = ds_add

    assert_equal 1, code
    assert_equal "datasource_exists", envelope.dig("error", "code")
    assert_includes envelope.dig("error", "fix"), "new id"
  end

  def test_a_setup_token_refused_on_a_set_up_organization_says_so
    refused = Vkit::CLI::API::APIError.from_body(403, { "error" => "This organization is already set up",
                                                       "code" => "setup_scope_forbidden" })
    FakeBackend.client = existing_client(post: refused)

    envelope, code, = ds_add

    assert_equal 1, code
    assert_equal "setup_scope_forbidden", envelope.dig("error", "code")
    assert_includes envelope.dig("error", "fix"), "vkit login"
  end

  def test_a_new_control_plane_answering_already_existed_to_the_create
    FakeBackend.client = FakeClient.new([:get, "#{DS}/shop"] => not_found,
                                        [:post, DS] => EXISTING.merge("already_existed" => true))
    ENV["SHOP_PW"] = SECRET

    envelope, code, = ds_add("--password-env", "SHOP_PW")

    assert_equal 0, code
    assert_equal true, envelope.dig("result", "already_existed")
  end

  def test_an_existing_id_never_asks_for_the_password
    FakeBackend.client = existing_client
    stubbing(Vkit::CLI::SecretInput, :from_tty, ->(*) { flunk "the password shouldn't be read" }) do
      envelope, code, = ds_add("--password-prompt")

      assert_equal 0, code
      assert_equal true, envelope.dig("result", "already_existed")
      assert_includes envelope.dig("result", "warning"), "can't change a stored credential"
    end
  end

  def test_init_twice_is_ok_and_changes_nothing
    Dir.mktmpdir do |root|
      dir = File.join(root, "p")
      first, code, = cli("init", "--dir", dir)
      assert_equal 0, code
      assert_equal false, first.dig("result", "already_existed")
      before = Dir.glob("#{dir}/**/*", File::FNM_DOTMATCH).reject { |f| f.include?("/.git/") }
                  .to_h { |f| [f, File.file?(f) ? File.read(f) : nil] }

      second, code, = cli("init", "--dir", dir)

      assert_equal 0, code
      assert_equal true, second.dig("result", "already_existed")
      assert_equal 0, second.dig("result", "policies_added")
      after = Dir.glob("#{dir}/**/*", File::FNM_DOTMATCH).reject { |f| f.include?("/.git/") }
                 .to_h { |f| [f, File.file?(f) ? File.read(f) : nil] }
      assert_equal before, after
    end
  end

  def test_policy_pack_info_shows_the_description_from_metadata_yaml
    description = YAML.safe_load(File.read(File.expand_path("../lib/vkit/policy/packs/ai_safety/metadata.yaml", __dir__)))
                      .dig("__pack_meta", "description")
    Dir.mktmpdir do |root|
      dir = File.join(root, "p")
      cli("init", "--dir", dir, "--no-git")

      envelope, code, = cli("policy", "pack", "info", "ai_safety", "--dir", dir)
      assert_equal 0, code
      assert_equal description, envelope.dig("result", "description")

      out, = capture_io { Vkit::CLI::Commands::PolicyPackInfoCommand.new.call(pack_name: "ai_safety", dir: dir) }
      assert_includes out, "Description: #{description}"
    end
  end

  def test_policy_pack_add_for_an_installed_pack
    Dir.mktmpdir do |root|
      dir = File.join(root, "p")
      cli("init", "--dir", dir, "--no-git")

      envelope, code, = cli("policy", "pack", "add", "starter", "--dir", dir)

      assert_equal 0, code
      assert_equal true, envelope.dig("result", "already_existed")
    end
  end

  def test_policy_pack_add_for_an_installed_pack_in_human_mode_is_no_longer_an_error
    Dir.mktmpdir do |root|
      dir = File.join(root, "p")
      capture_io { Vkit::CLI::Commands::InitCommand.new.call(dir: dir, packs: nil, git: false) }

      out, = capture_io { Vkit::CLI::Commands::PolicyPackAddCommand.new.call(pack_name: "starter", dir: dir) }

      assert_includes out, "starter is already installed"
    end
  end
end

class PolicyDeployIdempotencyTest < Minitest::Test
  include JsonTestHelpers

  BUNDLES = "/api/v1/orgs/acme/policy_bundles"
  CONFLICT = Vkit::CLI::API::APIError.new(409, "conflict")

  def deploy(client, dirty: false)
    FakeBackend.client = client
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bundle.json")
      File.write(path, JSON.generate("bundle" => { "bundle_version" => "abc123", "checksum" => "c1",
                                                    "source" => { "dirty" => dirty } }, "policies" => []))
      cli("policy", "deploy", "--bundle", path)
    end
  end

  def test_the_active_version_again_is_already_deployed
    envelope, code, = deploy(FakeClient.new([:post, BUNDLES] => CONFLICT,
                                            [:get, "/api/v1/orgs/acme/setup"] => { "active_policy" => { "version" => "abc123" } }))

    assert_equal 0, code
    assert_equal "ok", envelope["status"]
    assert_equal true, envelope.dig("result", "already_deployed")
  end

  def test_production_answers_500_and_that_is_checked_the_same_way
    envelope, code, = deploy(FakeClient.new([:post, BUNDLES] => Vkit::CLI::API::APIError.new(500, "Internal server error"),
                                            [:get, "/api/v1/orgs/acme/setup"] => { "active_policy" => { "version" => "abc123" } }))

    assert_equal 0, code
    assert_equal true, envelope.dig("result", "already_deployed")
  end

  def test_an_uploaded_but_inactive_version_is_an_error_with_a_fix
    envelope, code, = deploy(FakeClient.new([:post, BUNDLES] => CONFLICT,
                                            [:get, "/api/v1/orgs/acme/setup"] => { "active_policy" => { "version" => "other" } }))

    assert_equal 1, code
    assert_equal "bundle_version_exists", envelope.dig("error", "code")
    assert_includes envelope.dig("error", "fix"), "vkit policy bundle"
  end

  # vaultkit#126 on: the same bundle again is a 200 with already_existed.
  def test_the_same_bundle_again_is_already_deployed_without_a_409
    envelope, code, = deploy(FakeClient.new([:post, BUNDLES] => { "status" => "ok", "bundle_version" => "abc123",
                                                                  "checksum" => "c1", "state" => "active",
                                                                  "already_existed" => true }))

    assert_equal 0, code
    assert_equal true, envelope.dig("result", "already_deployed")
    assert_equal true, envelope.dig("result", "already_existed")
    assert_equal "active", envelope.dig("result", "state")
  end

  def test_the_same_bundle_uploaded_but_not_active_is_already_existed_not_deployed
    envelope, code, = deploy(FakeClient.new([:post, BUNDLES] => { "bundle_version" => "abc123", "state" => "uploaded",
                                                                  "already_existed" => true }))

    assert_equal 0, code
    assert_equal false, envelope.dig("result", "already_deployed")
    assert_equal true, envelope.dig("result", "already_existed")
  end

  def test_new_409_codes_map_with_fixes_and_skip_the_active_version_guess
    { "bundle_version_exists" => "vkit policy bundle", "bundle_checksum_exists" => "already uploaded" }.each do |code, fix|
      conflict = Vkit::CLI::API::APIError.from_body(409, { "error" => "conflict", "code" => code,
                                                          "bundle_version" => "abc123", "state" => "active" })
      client = FakeClient.new([:post, BUNDLES] => conflict)

      envelope, exit_code, = deploy(client)

      assert_equal 1, exit_code
      assert_equal code, envelope.dig("error", "code")
      assert_includes envelope.dig("error", "fix"), fix
      assert_equal "abc123", envelope.dig("result", "conflicting_version")
      assert client.calls.none? { |_, path, _| path.end_with?("/setup") }, "a coded 409 is not guessed at"
    end
  end

  def test_a_dirty_bundle_is_never_assumed_deployed
    envelope, = deploy(FakeClient.new([:post, BUNDLES] => CONFLICT,
                                      [:get, "/api/v1/orgs/acme/setup"] => { "active_policy" => { "version" => "abc123" } }),
                       dirty: true)

    assert_equal "bundle_version_exists", envelope.dig("error", "code")
  end
end

class BundleProvenanceEnvelopeTest < Minitest::Test
  include JsonTestHelpers

  GIT_ENV = { "GIT_AUTHOR_NAME" => "T", "GIT_AUTHOR_EMAIL" => "t@x.test",
              "GIT_COMMITTER_NAME" => "T", "GIT_COMMITTER_EMAIL" => "t@x.test" }.freeze

  def test_bundle_not_committed_and_not_versioned_come_through_with_their_fixes
    Dir.mktmpdir do |root|
      dir = File.join(root, "p")
      cli("init", "--dir", dir)

      Dir.chdir(dir) do
        envelope, code, = cli("policy", "bundle")
        assert_equal 1, code
        assert_equal "bundle_not_versioned", envelope.dig("error", "code")
        assert_includes envelope.dig("error", "fix"), "git init"

        system(GIT_ENV, "git", "add", "-A", out: File::NULL) && system(GIT_ENV, "git", "commit", "-qm", "x", out: File::NULL)
        File.write("datasets/registry.yaml", "# edited\n", mode: "a")

        envelope, code, = cli("policy", "bundle")
        assert_equal 1, code
        assert_equal "bundle_not_committed", envelope.dig("error", "code")
        assert_includes envelope.dig("error", "message"), "datasets/registry.yaml"
        assert_includes envelope.dig("error", "fix"), "git commit"
        refute_includes envelope.dig("error", "fix"), "--allow-dirty"
        assert_equal "git add -A -- config/policies datasets .vkit/packs.yaml; git commit -m \"Update VaultKit policies\"", envelope.dig("error", "fix")
      end
    end
  end
end

# setup.md reruns every step: bundling the same commit again, later, and
# deploying it must be a no-op, against a control plane that (like
# vaultkit's PolicyBundles::Validator and #existing_upload) recomputes the
# checksum over the whole bundle and takes each version once.
class BundleRebuildRedeployTest < Minitest::Test
  include JsonTestHelpers

  GIT_ENV = { "GIT_AUTHOR_NAME" => "T", "GIT_AUTHOR_EMAIL" => "t@x.test",
              "GIT_COMMITTER_NAME" => "T", "GIT_COMMITTER_EMAIL" => "t@x.test" }.freeze

  def control_plane
    uploaded = {}
    post = lambda do |body|
      bundle = body[:bundle]
      meta = bundle["bundle"]
      recomputed = Digest::SHA256.hexdigest(
        Vkit::Policy::BundleCompiler.canonical_json(bundle.merge("bundle" => meta.merge("checksum" => "")))
      )
      raise "checksum mismatch" unless recomputed == meta["checksum"]

      version = meta["bundle_version"]
      answer = { "status" => "ok", "bundle_version" => version, "checksum" => meta["checksum"], "state" => "active" }
      if uploaded.key?(version)
        next answer.merge("already_existed" => true) if uploaded[version] == meta["checksum"]

        raise Vkit::CLI::API::APIError.from_body(409, { "error" => "already uploaded with other contents",
                                                        "code" => "bundle_version_exists",
                                                        "bundle_version" => version, "state" => "active" })
      end
      uploaded[version] = meta["checksum"]
      answer.merge("warnings" => [])
    end
    FakeClient.new([:post, "/api/v1/orgs/acme/policy_bundles"] => post)
  end

  # Bundles and deploys at `now`, after touching every input file.
  def bundle_and_deploy(now)
    FileUtils.touch(Dir.glob("{config,datasets,.vkit}/**/*", File::FNM_DOTMATCH).select { |f| File.file?(f) }, mtime: now)
    stubbing(Time, :now, -> { now }) do
      bundled, code, = cli("policy", "bundle")
      assert_equal 0, code, bundled.inspect
      deployed, code, = cli("policy", "deploy", "--bundle", "dist/policy_bundle.json")
      assert_equal 0, code, deployed.inspect
      [bundled, deployed, JSON.parse(File.read("dist/policy_bundle.json"))]
    end
  end

  def in_committed_project
    ENV.update(GIT_ENV)
    Dir.mktmpdir do |root|
      dir = File.join(root, "p")
      cli("init", "--dir", dir)
      Dir.chdir(dir) do
        system("git", "add", "-A", out: File::NULL) && system("git", "commit", "-qm", "Policies", out: File::NULL) or flunk "commit failed"
        yield
      end
    end
  end

  def test_rebuilding_the_same_commit_later_gives_the_same_checksum_and_redeploys_as_already_deployed
    FakeBackend.client = control_plane
    in_committed_project do
      first_bundle, first_deploy, first = bundle_and_deploy(Time.utc(2026, 11, 1, 9))
      second_bundle, second_deploy, second = bundle_and_deploy(Time.utc(2026, 11, 2, 17))

      assert_equal false, first_deploy.dig("result", "already_deployed")
      assert_equal first_bundle.dig("result", "checksum"), second_bundle.dig("result", "checksum")
      assert_equal first, second
      assert_equal true, second_deploy.dig("result", "already_deployed"), second_deploy.inspect
      commit_time = Time.iso8601(`git show -s --format=%cI HEAD`.strip).utc.iso8601
      assert_equal commit_time, second.dig("bundle", "created_at")
    end
  end

  def test_a_new_commit_is_a_new_version_with_a_new_checksum
    in_committed_project do
      first, = cli("policy", "bundle")
      File.write("datasets/registry.yaml", "# edited\n", mode: "a")
      system("git", "commit", "-qam", "Edit", out: File::NULL) or flunk "commit failed"
      second, = cli("policy", "bundle")

      refute_equal first.dig("result", "bundle_version"), second.dig("result", "bundle_version")
      refute_equal first.dig("result", "checksum"), second.dig("result", "checksum")
    end
  end
end

class PromptsBecomeNeedsInputTest < Minitest::Test
  include JsonTestHelpers

  def assert_needs_input(*argv, code: "confirmation_required")
    stubbing($stdin, :gets, -> { flunk "prompted on stdin" }) do
      envelope, exit_code, = cli(*argv)

      assert_equal 3, exit_code, envelope.inspect
      assert_equal "needs_input", envelope["status"]
      assert_equal code, envelope.dig("error", "code")
      envelope
    end
  end

  def test_reset
    envelope = assert_needs_input("reset")
    assert_includes envelope.dig("error", "fix"), "--yes"
  end

  def test_grant_revoke
    FakeBackend.client = FakeClient.new
    assert_needs_input("grant:revoke", "--grant", "g1", "--reason", "done")
  end

  def test_policy_revoke
    FakeBackend.client = FakeClient.new
    assert_needs_input("policy", "revoke", "--bundle-version", "v1")
  end

  def test_agents_tokens_revoke
    FakeBackend.client = FakeClient.new([:get, "/api/v1/orgs/acme/agent_tokens"] =>
                                          { "tokens" => [{ "id" => "t1", "prefix" => "vkit_agent_ab", "name" => "bot" }] })
    assert_needs_input("agents", "tokens", "revoke", "--token", "t1", "--reason", "rotated")
  end

  def test_approval_deny_without_a_reason
    FakeBackend.client = FakeClient.new
    assert_needs_input("approval:deny", "a1", code: "reason_required")
  end

  def test_yes_answers_the_confirmation
    FakeBackend.client = FakeClient.new([:post, "/api/v1/orgs/acme/grants/g1/revoke"] => { "revoked_at" => "now" })

    envelope, code, = cli("grant:revoke", "--grant", "g1", "--reason", "done", "--yes")

    assert_equal 0, code
    assert_equal "now", envelope.dig("result", "revoked_at")
  end

  def test_registry_export_over_an_existing_file_and_force_overwrites_without_asking
    registry = { "orders" => { "fields" => { "id" => { "sensitivity" => "low" } } } }
    FakeBackend.client = FakeClient.new([:get, "/api/v1/orgs/acme/registries/export"] => registry)

    Dir.mktmpdir do |root|
      dir = File.join(root, "p")
      cli("init", "--dir", dir, "--no-git")

      assert_needs_input("registry", "export", "--dir", dir, code: "overwrite_confirmation_required")

      stubbing($stdin, :gets, -> { flunk "prompted on stdin" }) do
        envelope, code, = cli("registry", "export", "--dir", dir, "--force")
        assert_equal 0, code
        assert_equal true, envelope.dig("result", "overwritten")
      end
      assert_equal registry, YAML.safe_load(File.read(File.join(dir, "datasets", "registry.yaml")))
    end
  end

  def test_pack_upgrade_with_missing_files
    Dir.mktmpdir do |root|
      dir = File.join(root, "p")
      cli("init", "--dir", dir, "--no-git")
      File.delete(Dir[File.join(dir, "config", "policies", "starter__01__*.yaml")].first)

      envelope = assert_needs_input("policy", "pack", "upgrade", "starter", "--dir", dir)
      assert_includes envelope.dig("error", "fix"), "--restore"

      envelope, code, = cli("policy", "pack", "upgrade", "starter", "--dir", dir, "--restore")
      assert_equal 0, code
      assert_equal "restored", envelope.dig("result", "packs", 0, "status")
    end
  end
end

class ScanJsonTest < Minitest::Test
  include JsonTestHelpers

  SCAN = "/api/v1/orgs/acme/datasources/shop/scan"
  EXPORT = "/api/v1/orgs/acme/registries/export"

  def scan_response
    { "datasource" => "shop", "scan_id" => "s1", "mode" => "diff_only", "applied" => nil,
      "diff" => { "datasets" => [{
        "name" => "customers",
        "changes" => {
          "added_fields" => [{ "name" => "notes", "type" => "text", "sensitivity" => "unknown", "tags" => ["unknown"] }],
          "removed_fields" => [{ "name" => "legacy", "type" => "text" }],
          "changed_fields" => []
        },
        "suggestions" => [{ "name" => "email", "current" => { "sensitivity" => "low", "tags" => ["internal"] },
                            "suggested" => { "sensitivity" => "high", "tags" => ["pii"] } }],
        "unreviewed" => ["notes"]
      }] } }
  end

  def registry
    { "customers" => { "fields" => { "id" => { "type" => "integer", "sensitivity" => "low", "category" => "internal" },
                                     "email" => { "type" => "text", "sensitivity" => "low", "category" => "internal" },
                                     "legacy" => { "type" => "text", "sensitivity" => "low", "category" => "internal" } } } }
  end

  def test_every_column_with_its_classification_review_state_and_suggestion
    FakeBackend.client = FakeClient.new([:post, SCAN] => scan_response, [:get, EXPORT] => registry)

    envelope, code, err = cli("scan", "shop")

    assert_equal 0, code
    assert_includes err, "Scanning shop"
    result = envelope["result"]
    assert_equal true, result["columns_complete"]
    assert_equal 1, result["unreviewed_count"]
    columns = result["datasets"][0]["columns"].to_h { |c| [c["name"], c] }
    assert_equal %w[email id legacy notes], columns.keys.sort

    assert_equal({ "name" => "id", "type" => "integer", "sensitivity" => "low", "category" => "internal",
                   "change" => nil, "unreviewed" => false, "unknown" => false, "suggestion" => nil }, columns["id"])
    assert_equal true, columns["notes"]["unknown"]
    assert_equal true, columns["notes"]["unreviewed"]
    assert_equal "added", columns["notes"]["change"]
    assert_equal "removed", columns["legacy"]["change"]
    assert_equal({ "sensitivity" => "high", "category" => "pii", "tags" => ["pii"] },
                 columns["email"]["suggestion"]["suggested"])
    assert_equal ["vkit scan shop --mode apply --format json"], envelope["next"]
  end

  def test_apply_mode_points_at_the_registry_review
    FakeBackend.client = FakeClient.new([:post, SCAN] => scan_response.merge("applied" => true), [:get, EXPORT] => registry)

    envelope, = cli("scan", "shop", "--mode", "apply")

    assert_equal true, envelope.dig("result", "applied")
    assert_equal "vkit registry export --force --format json", envelope["next"].first
  end

  def test_without_the_registry_only_changed_columns_are_listed
    FakeBackend.client = FakeClient.new([:post, SCAN] => scan_response,
                                        [:get, EXPORT] => Vkit::CLI::API::APIError.new(500, "Registry export failed"))

    envelope, code, = cli("scan", "shop")

    assert_equal 0, code
    assert_equal false, envelope.dig("result", "columns_complete")
    assert_equal %w[email legacy notes], envelope.dig("result", "datasets", 0, "columns").map { |c| c["name"] }.sort
  end

  def test_human_output_is_unchanged
    FakeBackend.client = FakeClient.new([:post, SCAN] => scan_response)

    out, = capture_io { Vkit::CLI::BaseCLI.start(%w[scan shop]) }

    assert_includes out, "+ notes (text)  ⚠️  unclassified"
    assert_includes out, "? email  low/internal → high/pii (suggested)"
    assert_equal [[:post, SCAN, { datasource: "shop", mode: "diff_only" }]], FakeBackend.client.calls
  end
end

class RegistryDiffJsonTest < Minitest::Test
  include JsonTestHelpers

  def test_keeps_its_exit_codes
    Dir.mktmpdir do |root|
      dir = File.join(root, "p")
      cli("init", "--dir", dir, "--no-git")
      File.write(File.join(dir, "datasets", "registry.yaml"), { "orders" => { "fields" => {} } }.to_yaml)

      FakeBackend.client = FakeClient.new([:get, "/api/v1/orgs/acme/registries/export"] => { "orders" => { "fields" => {} } })
      envelope, code, = cli("registry", "diff", "--dir", dir)
      assert_equal 0, code
      assert_equal false, envelope.dig("result", "changed")

      FakeBackend.client = FakeClient.new([:get, "/api/v1/orgs/acme/registries/export"] =>
                                            { "orders" => { "fields" => { "id" => { "sensitivity" => "low" } } } })
      envelope, code, = cli("registry", "diff", "--dir", dir)
      assert_equal 1, code
      assert_equal "ok", envelope["status"]
      assert_equal true, envelope.dig("result", "changed")

      File.delete(File.join(dir, "datasets", "registry.yaml"))
      envelope, code, = cli("registry", "diff", "--dir", dir)
      assert_equal 2, code
      assert_equal "registry_not_found", envelope.dig("error", "code")
    end
  end
end

class AgentTokenSecretTest < Minitest::Test
  include JsonTestHelpers

  TOKEN_SECRET = "vkit_agent_abcdef_supersecretvalue"

  def client
    FakeClient.new([:post, "/api/v1/orgs/acme/agent_tokens"] =>
                     { "token" => { "id" => "t1", "name" => "bot", "prefix" => "vkit_agent_abcdef", "role" => "agent",
                                    "tenant" => "t" }, "secret" => TOKEN_SECRET })
  end

  def test_json_needs_a_secret_file_and_issues_nothing_without_one
    FakeBackend.client = client

    envelope, code, = cli("agents", "tokens", "create", "--name", "bot")

    assert_equal 3, code
    assert_equal "secret_file_required", envelope.dig("error", "code")
    assert_empty FakeBackend.client.calls
  end

  def test_the_token_goes_to_the_file_only
    FakeBackend.client = client
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bot.token")

      envelope, code, err, out = cli("agents", "tokens", "create", "--name", "bot", "--secret-file", path)

      assert_equal 0, code
      assert_equal TOKEN_SECRET, File.read(path)
      assert_equal "600", format("%o", File.stat(path).mode & 0o777)
      assert_equal path, envelope.dig("result", "secret_file")
      refute_leaks(out, err, secrets: [TOKEN_SECRET, FakeStore.new.token])
    end
  end
end

class LoginJsonTest < Minitest::Test
  include JsonTestHelpers

  def test_password_login_never_reads_stdin_and_hands_over_to_the_person
    discovery = { "preferred" => "password" }
    stubbing(Vkit::Core::AuthClient, :new, ->(**) { Struct.new(:discover).new(discovery) }) do
      stubbing($stdin, :gets, -> { flunk "read stdin" }) do
        envelope, code, = cli("login", "--endpoint", "http://cp.test", "--email", "a@x.test")

        assert_equal 3, code
        assert_equal "secret_required", envelope.dig("error", "code")
        assert_includes envelope.dig("error", "fix"), "--password-prompt"
      end
    end
  end

  def test_no_endpoint_is_needs_input
    FakeBackend.store = FakeStore.new(token: nil, endpoint: nil)
    FakeBackend.store.define_singleton_method(:stored_payload) { nil }
    ENV.delete("VKIT_ENDPOINT")

    envelope, code, = cli("login")

    assert_equal 3, code
    assert_equal "endpoint_required", envelope.dig("error", "code")
  end
end

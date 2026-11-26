# frozen_string_literal: true

# Run with: ruby -Ilib test/doctor_test.rb
#
# vkit doctor with the control plane, RubyGems and the MCP server faked: each
# check's pass and fail paths, dependent checks being skipped, the exit code
# and envelope, and tokens never appearing in the output.
require "minitest/autorun"
require "json"
require "base64"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require_relative "support/envelope"
require_relative "../lib/vkit/cli/doctor"

module DoctorTestSupport
  include EnvelopeHelper

  ENDPOINT = "http://cp.test"
  AGENT_BASE = "http://agent-cp.test"
  AGENT_TOKEN = "vkat_agent_secret_token_0123456789"
  NOW = Time.utc(2026, 11, 25, 12, 0, 0)

  # Answers by "METHOD path"; a value that's an exception is raised.
  class FakeClient
    attr_reader :calls

    def initialize(routes)
      @routes = routes
      @calls = []
    end

    def get(path, params: {}) # rubocop:disable Lint/UnusedMethodArgument
      answer("GET #{path}")
    end

    def post(path, body:)
      answer("POST #{path}", body)
    end

    private

    def answer(key, body = nil)
      @calls << [key, body]
      raise "unexpected request: #{key}" unless @routes.key?(key)

      value = @routes[key]
      value = value.call if value.is_a?(Proc)
      raise value if value.is_a?(Exception)

      value
    end
  end

  FakeStore = Struct.new(:endpoint, :token)

  def api_error(status, body)
    Vkit::CLI::API::APIError.from_body(status, body)
  end

  def jwt(exp)
    part = ->(h) { Base64.urlsafe_encode64(JSON.generate(h), padding: false) }
    "#{part.call(alg: 'HS256')}.#{part.call(sub: '1', exp: exp.to_i)}.c2lnbmF0dXJl"
  end

  def login_token
    @login_token ||= jwt(NOW + 3600)
  end

  def no_changes
    { "added_fields" => [], "removed_fields" => [], "changed_fields" => [] }
  end

  # A control plane where everything is set up.
  def login_routes
    @login_routes ||= {
      "GET /auth/whoami" => { "type" => "user",
                              "user" => { "email" => "ada@acme.test", "role" => "admin",
                                          "organization_slug" => "acme" } },
      "GET /api/v1/orgs/acme/datasources" => [{ "name" => "pg" }],
      "POST /api/v1/orgs/acme/datasources/pg/scan" => {
        "diff" => { "datasets" => [{ "name" => "orders", "changes" => no_changes, "unreviewed" => [] }] }
      },
      "GET /api/v1/orgs/acme/registries/export" => {
        "orders" => { "datasource" => "pg", "fields" => { "id" => { "type" => "integer", "sensitivity" => "low" },
                                                          "email" => { "sensitivity" => "medium",
                                                                       "category" => "pii" } } }
      },
      "GET /api/v1/orgs/acme/approval_groups" => -> {
        { "policy_bundle_version" => @active_version || head,
          "groups" => [{ "name" => "security", "member_count" => 2, "active_member_count" => 2,
                         "policy_count" => 1, "admin_fallback" => false }] }
      }
    }
  end

  def agent_routes
    @agent_routes ||= {
      "GET /auth/whoami" => { "type" => "agent", "agent" => { "name" => "billing-bot", "role" => "agent" } },
      "GET /api/v1/orgs/acme/aql/datasets" => { "datasets" => [{ "name" => "orders" }, { "name" => "customers" }] }
    }
  end

  def env
    @env ||= { "VAULTKIT_BASE_URL" => AGENT_BASE, "VAULTKIT_ORG" => "acme", "VAULTKIT_TOKEN" => AGENT_TOKEN,
               "PATH" => "/usr/bin" }
  end

  def http_routes
    @http_routes ||= {
      Vkit::CLI::Doctor::RUBYGEMS_LATEST => [200, JSON.generate("version" => Vkit::VERSION)],
      "#{ENDPOINT}/up" => [200, ""]
    }
  end

  def http_get
    lambda do |url, _timeout|
      answer = http_routes.fetch(url) { raise "unexpected GET #{url}" }
      raise answer if answer.is_a?(Exception)

      answer
    end
  end

  def clients
    @clients ||= {}
  end

  def client_for
    lambda do |base, token|
      routes =
        if base == ENDPOINT && token == store.token then login_routes
        elsif token == AGENT_TOKEN then agent_routes
        else @other_routes || raise("no client for #{base}")
        end
      clients[[base, token]] ||= FakeClient.new(routes)
    end
  end

  def store
    @store ||= FakeStore.new(ENDPOINT, login_token)
  end

  # A committed policy project.
  def project
    @project ||= begin
      dir = Dir.mktmpdir("vkit-doctor")
      FileUtils.mkdir_p(File.join(dir, "config/policies"))
      FileUtils.mkdir_p(File.join(dir, "datasets"))
      File.write(File.join(dir, "config/policies/01_deny.yaml"), "id: deny_credentials\n")
      File.write(File.join(dir, "datasets/registry.yaml"), "datasets: {}\n")
      git(dir, "init", "-q")
      commit(dir, "Add policies")
      dir
    end
  end

  def git(dir, *args)
    out, err, status = Open3.capture3("git", "-c", "user.email=t@t.test", "-c", "user.name=T",
                                      "-c", "commit.gpgsign=false", *args, chdir: dir)
    raise "git #{args.join(' ')}: #{err}" unless status.success?

    out.strip
  end

  def commit(dir, message)
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", message)
  end

  def head
    git(project, "rev-parse", "HEAD")
  end

  def teardown
    FileUtils.rm_rf(@project) if @project
  end

  def runner(**overrides)
    Vkit::CLI::Doctor::Runner.new(
      store: store, env: env, project_root: project, now: -> { NOW }, client_for: client_for,
      http_get: http_get, mcp_probe: @mcp_probe || ->(*) { raise "MCP probe not expected" },
      which: @which || ->(_) { nil }, **overrides
    )
  end

  def run_doctor(**overrides)
    r = runner(**overrides).run
    [r, r.to_h]
  end

  def check(name, report = run_doctor.last)
    report["checks"].find { |c| c["name"] == name }
  end

  def skipped(name, report)
    report["skipped"].find { |s| s["name"] == name }
  end
end

class DoctorHealthyTest < Minitest::Test
  include DoctorTestSupport

  def test_everything_set_up_passes_except_the_unverifiable_role_check
    runner, report = run_doctor

    refute runner.failed?
    statuses = report["checks"].to_h { |c| [c["name"], c["status"]] }
    assert_equal({ "cli_version" => "pass", "control_plane" => "pass", "login" => "pass", "datasources" => "pass",
                   "datasource_role" => "warn", "schema" => "pass", "policy_bundle" => "pass",
                   "approval_routing" => "pass", "agent_token" => "pass" }, statuses)
    assert_equal %w[mcp_server], report["skipped"].map { |s| s["name"] }
    assert_equal({ "pass" => 8, "warn" => 1, "fail" => 0 }, report["summary"])
    report["checks"].each { |c| assert_equal %w[name status detail fix], c.keys.first(4) }
  end

  def test_checks_run_in_order
    _, report = run_doctor
    order = Vkit::CLI::Doctor::LABELS.keys
    names = report["checks"].map { |c| c["name"] }
    assert_equal names, names.sort_by { |n| order.index(n) }
  end
end

class DoctorVersionTest < Minitest::Test
  include DoctorTestSupport

  def test_passes_on_the_latest_version
    assert_equal "pass", check("cli_version")["status"]
    assert_includes check("cli_version")["detail"], "the latest"
  end

  def test_warns_when_rubygems_has_a_newer_version
    http_routes[Vkit::CLI::Doctor::RUBYGEMS_LATEST] = [200, JSON.generate("version" => "99.0.0")]

    c = check("cli_version")
    assert_equal "warn", c["status"]
    assert_includes c["detail"], "99.0.0 is available"
    assert_equal "gem update vaultkit", c["fix"]
  end

  def test_offline_is_not_a_failure
    http_routes[Vkit::CLI::Doctor::RUBYGEMS_LATEST] = SocketError.new("getaddrinfo: nodename nor servname provided")

    c = check("cli_version")
    assert_equal "pass", c["status"]
    assert_includes c["detail"], "couldn't reach RubyGems"
  end
end

class DoctorControlPlaneTest < Minitest::Test
  include DoctorTestSupport

  def test_passes_when_the_health_check_answers
    assert_equal "pass", check("control_plane")["status"]
  end

  def test_fails_when_unreachable_and_skips_what_needs_it
    http_routes["#{ENDPOINT}/up"] = Errno::ECONNREFUSED.new("connect(2)")

    runner, report = run_doctor
    assert runner.failed?
    c = check("control_plane", report)
    assert_equal "fail", c["status"]
    assert_includes c["detail"], "Couldn't reach the control plane at #{ENDPOINT}"
    assert_includes c["fix"], "VKIT_ENDPOINT"
    %w[login datasources datasource_role schema policy_bundle approval_routing].each do |name|
      assert_equal "Control plane failed.", skipped(name, report)["reason"], name
    end
    # The agent's own credentials don't depend on vkit's login.
    assert_equal "pass", check("agent_token", report)["status"]
  end

  def test_fails_on_an_unhealthy_answer
    http_routes["#{ENDPOINT}/up"] = [503, ""]
    c = check("control_plane")
    assert_equal "fail", c["status"]
    assert_includes c["detail"], "HTTP 503"
  end

  def test_fails_with_no_endpoint_configured
    store.endpoint = nil
    c = check("control_plane")
    assert_equal "fail", c["status"]
    assert_includes c["fix"], "vkit login --endpoint"
  end
end

class DoctorLoginTest < Minitest::Test
  include DoctorTestSupport

  def test_passes_and_says_when_the_login_expires
    c = check("login")
    assert_equal "pass", c["status"]
    assert_includes c["detail"], "ada@acme.test (admin, org acme)"
    assert_includes c["detail"], "in 60 minutes"
    assert_equal "2026-11-25T13:00:00Z", c["expires_at"]
  end

  def test_reports_a_setup_session_and_its_expiry
    login_routes["GET /auth/whoami"] = login_routes["GET /auth/whoami"].merge(
      "setup_session" => { "scope" => "setup", "expires_at" => "2026-11-25T12:20:00Z" }
    )
    c = check("login")
    assert_equal "pass", c["status"]
    assert_includes c["detail"], "Setup session"
    assert_includes c["detail"], "in 20 minutes"
  end

  def test_warns_when_the_login_is_about_to_expire
    @login_token = jwt(NOW + 120)
    c = check("login")
    assert_equal "warn", c["status"]
    assert_includes c["fix"], "vkit login"
  end

  def test_fails_on_an_expired_login_and_skips_what_needs_it
    login_routes["GET /auth/whoami"] = api_error(401, { "error" => "Signature has expired" })

    runner, report = run_doctor
    assert runner.failed?
    c = check("login", report)
    assert_equal "fail", c["status"]
    assert_equal "Your VaultKit session has expired.", c["detail"]
    assert_includes c["fix"], "vkit login"
    assert_equal "Login failed.", skipped("datasources", report)["reason"]
    assert_equal "Login failed.", skipped("policy_bundle", report)["reason"]
  end

  def test_fails_when_vkit_runs_as_an_agent
    login_routes["GET /auth/whoami"] = { "type" => "agent", "agent" => { "name" => "billing-bot" } }
    c = check("login")
    assert_equal "fail", c["status"]
    assert_includes c["fix"], "Unset VKIT_TOKEN"
  end
end

class DoctorDatasourcesTest < Minitest::Test
  include DoctorTestSupport

  def test_passes_after_a_diff_only_scan_of_each
    runner, report = run_doctor
    assert_equal "pass", check("datasources", report)["status"]
    scan = clients[[ENDPOINT, login_token]].calls.find { |k, _| k.start_with?("POST") }
    assert_equal({ datasource: "pg", mode: "diff_only" }, scan.last)
    refute runner.failed?
  end

  def test_fails_with_no_datasources
    login_routes["GET /api/v1/orgs/acme/datasources"] = []
    _, report = run_doctor
    c = check("datasources", report)
    assert_equal "fail", c["status"]
    assert_includes c["fix"], "vkit datasource add"
    assert_equal "Datasources failed.", skipped("schema", report)["reason"]
    assert_equal "Datasources failed.", skipped("datasource_role", report)["reason"]
  end

  def test_maps_an_unreachable_datasource
    login_routes["POST /api/v1/orgs/acme/datasources/pg/scan"] = api_error(
      422, { "error" => "Funl error (datasource_unavailable): Couldn't reach the datasource at db:5432" }
    )
    c = check("datasources")
    assert_equal "fail", c["status"]
    assert_includes c["detail"], "datasource_unreachable"
    assert_includes c["fix"], "host and port"
  end

  def test_maps_a_failed_connection
    login_routes["POST /api/v1/orgs/acme/datasources/pg/scan"] = api_error(
      422, { "error" => "Funl error (datasource_unavailable): password authentication failed" }
    )
    c = check("datasources")
    assert_equal "fail", c["status"]
    assert_includes c["detail"], "datasource_connection_failed"
    assert_includes c["fix"], "username and password"
  end

  def test_warns_when_only_some_connect
    login_routes["GET /api/v1/orgs/acme/datasources"] = [{ "name" => "pg" }, { "name" => "old" }]
    login_routes["POST /api/v1/orgs/acme/datasources/old/scan"] = api_error(
      422, { "error" => "Funl error (datasource_unavailable): Couldn't reach the datasource" }
    )
    assert_equal "warn", check("datasources")["status"]
  end

  def test_a_member_who_isnt_an_admin_is_told_to_ask_one
    login_routes["GET /auth/whoami"]["user"]["role"] = "analyst"
    login_routes["GET /api/v1/orgs/acme/datasources"] = api_error(403, { "error" => "Forbidden" })
    runner, report = run_doctor
    s = skipped("datasources", report)
    assert_includes s["reason"], "Only org admins"
    assert_equal s["reason"], skipped("schema", report)["reason"]
    refute runner.failed?
  end
end

class DoctorDatasourceRoleTest < Minitest::Test
  include DoctorTestSupport

  def test_is_a_warning_that_links_the_issue
    c = check("datasource_role")
    assert_equal "warn", c["status"]
    assert_includes c["detail"], "Not verified"
    assert_includes c["fix"], "dedicated read-only role, not a superuser or the table owner"
    assert_includes c["fix"], "https://github.com/vaultkit-inc/vaultkit/issues/125"
  end

  def test_is_skipped_when_no_datasource_connects
    login_routes["POST /api/v1/orgs/acme/datasources/pg/scan"] = api_error(
      422, { "error" => "Funl error (datasource_unavailable): Couldn't reach the datasource" }
    )
    _, report = run_doctor
    assert_equal "Datasources failed.", skipped("datasource_role", report)["reason"]
  end
end

class DoctorSchemaTest < Minitest::Test
  include DoctorTestSupport

  def test_passes_when_scanned_and_classified
    c = check("schema")
    assert_equal "pass", c["status"]
    assert_includes c["detail"], "1 dataset, 2 columns"
  end

  def test_fails_when_a_datasource_was_never_scanned_in
    login_routes["GET /api/v1/orgs/acme/registries/export"] = {}
    c = check("schema")
    assert_equal "fail", c["status"]
    assert_includes c["fix"], "vkit scan pg --mode apply"
  end

  def test_warns_about_unclassified_columns
    login_routes["GET /api/v1/orgs/acme/registries/export"]["orders"]["fields"]["notes"] = { "sensitivity" => "unknown" }
    c = check("schema")
    assert_equal "warn", c["status"]
    assert_includes c["detail"], "orders.notes"
    assert_includes c["fix"], "datasets/registry.yaml"
  end

  def test_warns_when_the_schema_changed_since_the_last_scan
    login_routes["POST /api/v1/orgs/acme/datasources/pg/scan"] = {
      "diff" => { "datasets" => [{ "name" => "orders",
                                   "changes" => no_changes.merge("added_fields" => [{ "name" => "phone" }]),
                                   "unreviewed" => ["phone"] }] }
    }
    c = check("schema")
    assert_equal "warn", c["status"]
    assert_includes c["detail"], "pg/orders"
    assert_includes c["detail"], "orders.phone"
  end
end

class DoctorPolicyBundleTest < Minitest::Test
  include DoctorTestSupport

  def test_passes_when_head_is_active
    c = check("policy_bundle")
    assert_equal "pass", c["status"]
    assert_includes c["detail"], "HEAD"
  end

  def test_passes_when_later_commits_left_the_policies_alone
    @active_version = head
    File.write(File.join(project, "README.md"), "docs\n")
    commit(project, "Docs only")

    c = check("policy_bundle")
    assert_equal "pass", c["status"]
    assert_includes c["detail"], "same policies and registry"
  end

  def test_fails_when_the_policies_changed_after_the_active_bundle
    @active_version = head
    File.write(File.join(project, "config/policies/02_mask.yaml"), "id: mask_pii\n")
    commit(project, "Add a policy")

    c = check("policy_bundle")
    assert_equal "fail", c["status"]
    assert_includes c["detail"], "1 commit ahead"
    assert_equal "vkit policy bundle && vkit policy deploy", c["fix"]
  end

  def test_mentions_uncommitted_changes_without_failing
    File.write(File.join(project, "config/policies/01_deny.yaml"), "id: deny_credentials\npriority: 2\n")
    c = check("policy_bundle")
    assert_equal "pass", c["status"]
    assert_includes c["detail"], "Uncommitted changes (config/policies/01_deny.yaml)"
  end

  def test_fails_when_no_bundle_is_active
    @active_version = :none
    login_routes["GET /api/v1/orgs/acme/approval_groups"] = { "policy_bundle_version" => nil, "groups" => [] }
    c = check("policy_bundle")
    assert_equal "fail", c["status"]
    assert_includes c["detail"], "No policy bundle is active"
  end

  def test_warns_when_the_version_is_a_label
    @active_version = "release-7"
    c = check("policy_bundle")
    assert_equal "warn", c["status"]
    assert_includes c["detail"], "release-7"
    assert_includes c["detail"], "isn't a commit in this repository"
  end

  def test_warns_outside_a_policy_project
    dir = Dir.mktmpdir
    c = check("policy_bundle", run_doctor(project_root: dir).last)
    assert_equal "warn", c["status"]
    assert_includes c["fix"], "policy project"
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_falls_back_to_the_setup_endpoint
    login_routes["GET /api/v1/orgs/acme/approval_groups"] = api_error(500, { "error" => "boom" })
    login_routes["GET /api/v1/orgs/acme/setup"] = -> { { "active_policy" => { "version" => head } } }
    assert_equal "pass", check("policy_bundle")["status"]
  end
end

class DoctorApprovalRoutingTest < Minitest::Test
  include DoctorTestSupport

  def groups(*list)
    login_routes["GET /api/v1/orgs/acme/approval_groups"] = -> { { "policy_bundle_version" => head, "groups" => list } }
  end

  def test_a_group_with_no_members_is_information_not_a_warning
    groups({ "name" => "security", "active_member_count" => 2, "admin_fallback" => false, "policy_count" => 1 },
           { "name" => "finance", "active_member_count" => 0, "admin_fallback" => true, "policy_count" => 2 })
    c = check("approval_routing")
    assert_equal "pass", c["status"]
    assert_includes c["detail"], "finance has no members, so org admins approve its requests."
    assert_includes c["detail"], "security (2 members)"
  end

  def test_fails_only_when_the_endpoint_errors
    login_routes["GET /api/v1/orgs/acme/approval_groups"] = api_error(500, { "error" => "boom" })
    login_routes["GET /api/v1/orgs/acme/setup"] = -> { { "active_policy" => { "version" => head } } }
    c = check("approval_routing")
    assert_equal "fail", c["status"]
    assert_includes c["detail"], "boom"
  end

  def test_warns_when_an_older_control_plane_does_not_say_who_approves
    groups({ "name" => "finance", "member_count" => 0, "policy_count" => 2 })
    c = check("approval_routing")
    assert_equal "warn", c["status"]
    assert_includes c["detail"], "doesn't say who approves"
  end

  def test_no_groups
    groups
    assert_equal "pass", check("approval_routing")["status"]
  end
end

class DoctorAgentTokenTest < Minitest::Test
  include DoctorTestSupport

  def test_passes_with_a_working_agent_token
    c = check("agent_token")
    assert_equal "pass", c["status"]
    assert_includes c["detail"], "billing-bot"
    assert_includes c["detail"], "2 datasets"
    refute_includes c["detail"], AGENT_TOKEN
  end

  def test_fails_when_the_variables_are_missing
    env.delete("VAULTKIT_ORG")
    env.delete("VAULTKIT_TOKEN")
    _, report = run_doctor
    c = check("agent_token", report)
    assert_equal "fail", c["status"]
    assert_includes c["detail"], "VAULTKIT_ORG, VAULTKIT_TOKEN aren't set"
    assert_includes c["fix"], "vkit agents tokens create"
    assert_equal "Agent token failed.", skipped("mcp_server", report)["reason"]
  end

  def test_fails_when_vkit_token_is_the_agent_token
    env["VKIT_TOKEN"] = AGENT_TOKEN
    c = check("agent_token")
    assert_equal "fail", c["status"]
    assert_includes c["detail"], "VKIT_TOKEN is an agent token"
    assert_includes c["fix"], "Unset VKIT_TOKEN"
    refute_includes JSON.generate(c), AGENT_TOKEN
  end

  def test_fails_when_vkit_token_is_another_agent_token
    env["VKIT_TOKEN"] = "vkat_other_agent_token_987654"
    env["VKIT_ENDPOINT"] = "http://other.test"
    @other_routes = { "GET /auth/whoami" => { "type" => "agent", "agent" => { "name" => "other" } } }
    c = check("agent_token")
    assert_equal "fail", c["status"]
    assert_includes c["detail"], "VKIT_TOKEN is an agent token"
  end

  def test_a_person_s_vkit_token_is_fine
    env["VKIT_TOKEN"] = login_token
    assert_equal "pass", check("agent_token")["status"]
  end

  def test_fails_on_a_revoked_token
    agent_routes["GET /auth/whoami"] = api_error(401, { "error" => "Token revoked", "code" => "token_revoked" })
    c = check("agent_token")
    assert_equal "fail", c["status"]
    assert_includes c["detail"], "revoked"
    assert_includes c["fix"], "vkit agents tokens create"
  end

  def test_fails_on_a_person_s_login_in_vaultkit_token
    agent_routes["GET /auth/whoami"] = { "type" => "user", "user" => { "email" => "ada@acme.test" } }
    c = check("agent_token")
    assert_equal "fail", c["status"]
    assert_includes c["detail"], "a person's login"
  end

  def test_fails_on_the_wrong_org
    agent_routes["GET /api/v1/orgs/acme/aql/datasets"] = api_error(404, { "error" => "Not Found" })
    c = check("agent_token")
    assert_equal "fail", c["status"]
    assert_includes c["detail"], "VAULTKIT_ORG (acme)"
  end
end

class DoctorMcpTest < Minitest::Test
  include DoctorTestSupport

  def test_skipped_when_not_installed
    _, report = run_doctor
    s = skipped("mcp_server", report)
    assert_includes s["reason"], "Optional"
    assert_includes s["fix"], "vaultkit[mcp]"
  end

  def test_passes_when_it_lists_the_tools
    @which = ->(_) { "/usr/local/bin/vaultkit-mcp" }
    seen = nil
    @mcp_probe = lambda { |cmd, e|
      seen = [cmd, e["VAULTKIT_TOKEN"]]
      %w[vaultkit_discover vaultkit_describe vaultkit_query vaultkit_check_approval]
    }
    assert_equal "pass", check("mcp_server")["status"]
    assert_equal ["/usr/local/bin/vaultkit-mcp", AGENT_TOKEN], seen
  end

  def test_fails_when_tools_are_missing
    @which = ->(_) { "/usr/local/bin/vaultkit-mcp" }
    @mcp_probe = ->(*) { %w[vaultkit_discover] }
    c = check("mcp_server")
    assert_equal "fail", c["status"]
    assert_includes c["detail"], "vaultkit_query, vaultkit_check_approval"
  end

  def test_fails_when_it_does_not_start
    @which = ->(_) { "/usr/local/bin/vaultkit-mcp" }
    @mcp_probe = ->(*) { raise Vkit::CLI::Doctor::McpProbe::Failed, "it exited before answering" }
    c = check("mcp_server")
    assert_equal "fail", c["status"]
    assert_includes c["detail"], "exited before answering"
  end
end

# The probe itself, against small stdio servers.
class DoctorMcpProbeTest < Minitest::Test
  SERVER = <<~RUBY
    require "json"
    $stdout.sync = true
    $stderr.puts "starting"
    $stdin.each_line do |line|
      msg = JSON.parse(line)
      case msg["method"]
      when "initialize"
        puts JSON.generate(jsonrpc: "2.0", id: msg["id"], result: { protocolVersion: "2025-06-18", capabilities: {} })
      when "tools/list"
        puts JSON.generate(jsonrpc: "2.0", method: "notifications/message", params: {})
        puts JSON.generate(jsonrpc: "2.0", id: msg["id"],
                           result: { tools: [{ name: "vaultkit_discover" }, { name: ENV.fetch("EXTRA_TOOL") }] })
      end
    end
  RUBY

  def script(body)
    dir = Dir.mktmpdir
    path = File.join(dir, "server")
    File.write(path, "#!#{RbConfig.ruby}\n#{body}")
    File.chmod(0o755, path)
    @dirs = (@dirs || []) << dir
    path
  end

  def teardown
    Array(@dirs).each { |d| FileUtils.rm_rf(d) }
  end

  def test_lists_the_server_s_tools
    tools = Vkit::CLI::Doctor::McpProbe.new(timeout: 10).call(script(SERVER), { "EXTRA_TOOL" => "vaultkit_query" })
    assert_equal %w[vaultkit_discover vaultkit_query], tools
  end

  def test_a_server_that_exits_fails_with_its_last_stderr_line_and_no_token
    path = script(%($stderr.puts "Missing VAULTKIT_ORG for token vkat_secret_abc123"; exit 1))
    error = assert_raises(Vkit::CLI::Doctor::McpProbe::Failed) do
      Vkit::CLI::Doctor::McpProbe.new(timeout: 10).call(path, { "VAULTKIT_TOKEN" => "vkat_secret_abc123" })
    end
    assert_includes error.message, "Missing VAULTKIT_ORG"
    refute_includes error.message, "vkat_secret_abc123"
  end

  def test_a_server_that_never_answers_times_out
    path = script("sleep 30")
    error = assert_raises(Vkit::CLI::Doctor::McpProbe::Failed) do
      Vkit::CLI::Doctor::McpProbe.new(timeout: 1).call(path, {})
    end
    assert_includes error.message, "no answer within 1s"
  end
end

# The command: exit codes, the envelope, and no token in the output.
class DoctorCommandTest < Minitest::Test
  include DoctorTestSupport

  def command(runner)
    Vkit::CLI::Commands::DoctorCommand.new(runner: runner)
  end

  def test_ok_envelope_and_exit_zero_when_nothing_failed
    envelope, code, = run_json { command(runner).call }
    assert_equal 0, code
    assert_equal "ok", envelope["status"]
    assert_equal true, envelope["result"]["ok"]
    assert(envelope["result"]["checks"].all? { |c| %w[pass warn fail].include?(c["status"]) })
  end

  def test_error_envelope_and_exit_one_when_a_check_failed
    login_routes["GET /api/v1/orgs/acme/datasources"] = []
    envelope, code, = run_json { command(runner).call }
    assert_equal 1, code
    assert_equal "error", envelope["status"]
    assert_equal "doctor_checks_failed", envelope.dig("error", "code")
    assert_includes envelope.dig("error", "message"), "Datasources"
    assert_includes envelope.dig("error", "fix"), "vkit datasource add"
    assert_equal false, envelope["result"]["ok"]
    assert_equal "fail", envelope["result"]["checks"].find { |c| c["name"] == "datasources" }["status"]
  end

  def test_human_output_exits_one_on_failure
    login_routes["GET /api/v1/orgs/acme/datasources"] = []
    out, = capture_io do
      error = assert_raises(SystemExit) { command(runner).call }
      assert_equal 1, error.status
    end
    assert_includes out, "✗ Datasources"
    assert_includes out, "Fix: vkit datasource add"
    assert_includes out, "- MCP server"
  end

  def test_tokens_never_appear_in_the_envelope
    env["VKIT_TOKEN"] = AGENT_TOKEN
    login_routes["GET /auth/whoami"] = api_error(401, { "error" => "bad token #{login_token} #{AGENT_TOKEN}" })
    out = StringIO.new
    envelope, = run_json { command(runner).call }
    json = JSON.generate(envelope)
    refute_includes json, AGENT_TOKEN
    refute_includes json, login_token
    refute_includes out.string, AGENT_TOKEN
  end

  def test_doctor_is_a_command
    out, code, = run_cli("help", "doctor")
    assert_equal 0, code
    refute_empty out
  end
end

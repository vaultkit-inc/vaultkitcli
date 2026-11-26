# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "open3"
require "time"
require "uri"
require_relative "../version"
require_relative "../core/user_agent"
require_relative "../policy/git_state"
require_relative "../policy/pack_integrity"
require_relative "api/client"
require_relative "error_map"
require_relative "output"
require_relative "doctor/mcp_probe"

module Vkit
  module CLI
    # vkit doctor: whether VaultKit is set up and working from here, and
    # how to fix what isn't. Each check is { name, status, detail, fix };
    # a check that needs an earlier one that failed (or was skipped) is
    # skipped, with the reason, instead of failing for the same cause.
    #
    # Everything the checks touch is passed in, so tests can fake the
    # control plane, RubyGems, git and the MCP server.
    module Doctor
      PASS = "pass"
      WARN = "warn"
      FAIL = "fail"

      ROLE_SAFETY_ISSUE = "https://github.com/vaultkit-inc/vaultkit/issues/125"
      RUBYGEMS_LATEST = "https://rubygems.org/api/v1/versions/vaultkit/latest.json"
      MCP_TOOLS = %w[vaultkit_discover vaultkit_query vaultkit_check_approval].freeze
      AGENT_ENV = %w[VAULTKIT_BASE_URL VAULTKIT_ORG VAULTKIT_TOKEN].freeze
      # What a policy bundle is compiled from (see vkit policy bundle).
      BUNDLE_INPUTS = ["config/policies", "datasets", Vkit::Policy::PackIntegrity::TRACKING_PATH].freeze
      # A login this close to expiring is worth a warning: the next few
      # commands would fail part way.
      EXPIRY_WARNING_SECONDS = 10 * 60

      LABELS = {
        "cli_version" => "CLI version",
        "control_plane" => "Control plane",
        "login" => "Login",
        "datasources" => "Datasources",
        "datasource_role" => "Datasource role",
        "schema" => "Schema",
        "policy_bundle" => "Policy bundle",
        "approval_routing" => "Approval routing",
        "agent_token" => "Agent token",
        "mcp_server" => "MCP server"
      }.freeze

      Check = Struct.new(:name, :status, :detail, :fix, :extra, keyword_init: true) do
        def failed?
          status == FAIL
        end

        def to_h
          { "name" => name, "status" => status, "detail" => detail, "fix" => fix }.merge(extra || {})
        end
      end

      # A check that didn't run, and why (an earlier check failed, or it's
      # optional and there's nothing to check).
      Skip = Struct.new(:reason, :fix)

      # GET a URL with no credentials: [status, body]. Raises what Net::HTTP
      # raises when the host can't be reached.
      HTTP_GET = lambda do |url, timeout|
        uri = URI(url)
        req = Net::HTTP::Get.new(uri)
        req["User-Agent"] = Vkit::Core::UserAgent.to_s
        req["Accept"] = "application/json"
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                  open_timeout: timeout, read_timeout: timeout) do |http|
          http.request(req)
        end
        [res.code.to_i, res.body.to_s]
      end

      class Runner
        attr_reader :checks, :skipped

        # store: the CLI's credentials (Vkit::Core::CredentialStore).
        # client_for: ->(base_url, token) { an API client }.
        # http_get: ->(url, timeout) { [status, body] }, for requests without
        #   credentials (RubyGems, the control plane's health check).
        # mcp_probe: ->(command, env) { tool names }, raising on failure.
        def initialize(store:, env: ENV.to_h, project_root: Dir.pwd, now: -> { Time.now },
                       client_for: ->(base, token) { API::Client.new(base_url: base, token: token) },
                       http_get: HTTP_GET, mcp_probe: McpProbe.new, which: nil)
          @store = store
          @env = env
          @project_root = project_root
          @now = now
          @client_for = client_for
          @http_get = http_get
          @mcp_probe = mcp_probe
          @which = which || ->(cmd) { find_executable(cmd) }
        end

        def run
          @checks = []
          @skipped = []
          @ran = {}
          @skip_reasons = {}

          step("cli_version") { cli_version }
          step("control_plane") { control_plane }
          step("login", after: %w[control_plane]) { login }
          step("datasources", after: %w[login]) { datasources }
          step("datasource_role", after: %w[datasources]) { datasource_role }
          step("schema", after: %w[datasources]) { schema }
          step("policy_bundle", after: %w[login]) { policy_bundle }
          step("approval_routing", after: %w[login]) { approval_routing }
          step("agent_token") { agent_token }
          step("mcp_server", after: %w[agent_token]) { mcp_server }

          self
        end

        def failed?
          @checks.any?(&:failed?)
        end

        def to_h
          counts = %w[pass warn fail].to_h { |s| [s, @checks.count { |c| c.status == s }] }
          { "ok" => !failed?, "summary" => counts, "checks" => @checks.map(&:to_h), "skipped" => @skipped }
        end

        private

        # Runs a check unless one it needs failed or was skipped. A check
        # that raises something unexpected fails with the error, so one bug
        # never hides the other checks.
        def step(name, after: [])
          blocker = after.find { |n| !@ran.key?(n) || @ran[n].failed? }
          if blocker
            # A check skipped because of a skipped one gives the root cause.
            reason = @ran.key?(blocker) ? "#{LABELS[blocker]} failed." : @skip_reasons.fetch(blocker)
            @skip_reasons[name] = reason
            @skipped << { "name" => name, "reason" => reason }
            return
          end

          result = begin
            yield
          rescue StandardError => e
            mapped = ErrorMap.map(e)
            check(FAIL, mapped[:message].to_s, mapped[:fix])
          end

          if result.is_a?(Skip)
            @skip_reasons[name] = result.reason
            @skipped << { "name" => name, "reason" => result.reason, "fix" => result.fix }.compact
            return
          end

          result.name = name
          @ran[name] = result
          @checks << result
        end

        def check(status, detail, fix = nil, **extra)
          Check.new(status: status, detail: detail, fix: fix, extra: extra.empty? ? nil : extra.transform_keys(&:to_s))
        end

        # 1. This CLI's version, and whether RubyGems has a newer one. Being
        #    offline only means the newer-version check is left out.
        def cli_version
          latest = begin
            status, body = @http_get.call(RUBYGEMS_LATEST, 3)
            status == 200 ? JSON.parse(body)["version"] : nil
          rescue StandardError, Timeout::Error
            nil
          end

          current = Gem::Version.new(Vkit::VERSION)
          if latest.nil? || !Gem::Version.correct?(latest)
            return check(PASS, "vkit #{Vkit::VERSION} (couldn't reach RubyGems to check for a newer version).")
          end

          if Gem::Version.new(latest) > current
            return check(WARN, "vkit #{Vkit::VERSION}; #{latest} is available.", "gem update vaultkit")
          end

          check(PASS, "vkit #{Vkit::VERSION} (the latest).")
        end

        # 2. The control plane answers at the configured URL. Its health
        #    check needs no login, so this tells "down" from "logged out".
        def control_plane
          endpoint = begin
            @store.endpoint
          rescue Vkit::CLI::Error => e
            return check(FAIL, e.message, "Set both VKIT_ENDPOINT and VKIT_TOKEN, or unset the one that's set.")
          end

          if endpoint.to_s.strip.empty?
            return check(FAIL, "No control plane is configured: not logged in, and VKIT_ENDPOINT isn't set.",
                         "vkit login --endpoint <control plane URL>")
          end

          @endpoint = endpoint.chomp("/")
          status = health_status(@endpoint)
          return check(PASS, "Reachable at #{@endpoint}.") if status == 200

          check(FAIL, "#{@endpoint} answered HTTP #{status} to its health check (/up).",
                "Check that this is the control plane's URL and that it's healthy (its logs), then rerun.")
        rescue *ErrorMap::UNREACHABLE, Timeout::Error => e
          check(FAIL, "Couldn't reach the control plane at #{@endpoint}: #{e.message}",
                "Check that the control plane is running and the URL is right " \
                "(`vkit login --endpoint <url>`, or VKIT_ENDPOINT), then rerun.")
        end

        # /up is Rails' health check. Behind a proxy that doesn't pass it on,
        # the CLI's login discovery (/auth/cli) answers instead.
        def health_status(endpoint)
          status, = @http_get.call("#{endpoint}/up", 5)
          return status unless status == 404

          @http_get.call("#{endpoint}/auth/cli", 5).first
        end

        # 3. Logged in, as a person or a setup session, and until when.
        def login
          token = @store.token
          Output.register_secret(token)
          @client = @client_for.call(@endpoint, token)
          me = @client.get("/auth/whoami")

          if me["type"] == "agent"
            return check(FAIL, "vkit is signed in with an agent token (#{me.dig('agent', 'name')}) from VKIT_TOKEN, " \
                               "so every vkit command runs as that agent.",
                         "Unset VKIT_TOKEN and VKIT_ENDPOINT (use VAULTKIT_TOKEN for the agent), then `vkit login`.")
          end

          user = me["user"] || {}
          @org = user["organization_slug"]
          @role = user["role"]
          who = "#{user['email']} (#{@role}, org #{@org})"
          via = @env["VKIT_TOKEN"].to_s.strip.empty? ? "" : " via VKIT_ENDPOINT/VKIT_TOKEN"

          if (setup = me["setup_session"])
            expires_at = parse_time(setup["expires_at"])
            return expiry_check("Setup session#{via} (setup only), approved by #{user['email']} for org #{@org}",
                                expires_at,
                                "`vkit login --setup` for a new setup session.")
          end

          expiry_check("Signed in#{via} as #{who}", jwt_expiry(token), "`vkit login` to sign in again.")
        end

        def expiry_check(what, expires_at, renew)
          return check(PASS, "#{what}.") unless expires_at

          left = expires_at - @now.call
          when_text = "#{expires_at.localtime.strftime('%H:%M')} (#{duration(left)})"
          extra = { expires_at: expires_at.utc.iso8601 }
          if left <= 0
            return check(FAIL, "#{what}; the session expired at #{when_text}.", "Run #{renew}", **extra)
          end
          if left < EXPIRY_WARNING_SECONDS
            return check(WARN, "#{what}; the session expires at #{when_text}.", "Run #{renew}", **extra)
          end

          check(PASS, "#{what}; the session expires at #{when_text}.", **extra)
        end

        # 4. At least one datasource, and the control plane can connect to
        #    each. There's no connection test yet, so this runs vkit scan in
        #    diff_only mode: it reads the schema (never data) and changes
        #    nothing in the registry.
        def datasources
          list = begin
            @client.get(org_path("/datasources"))
          rescue API::APIError => e
            raise unless e.status == 403 && e.code != "setup_scope_forbidden"

            return Skip.new("Only org admins can see datasources; you're signed in as #{@role}.",
                            "Ask an org admin to run `vkit doctor`.")
          end
          names = Array(list).map { |d| d["name"] }.compact

          if names.empty?
            return check(FAIL, "No datasources in #{@org}.",
                         "vkit datasource add --id <name> --engine postgres --username <role> --password-prompt " \
                         "--config '<json>' --region <region> --environment <environment>, then rerun.")
          end

          @scans = {}
          failures = {}
          names.each do |name|
            @scans[name] = @client.post(org_path("/datasources/#{name}/scan"),
                                        body: { datasource: name, mode: "diff_only" })
          rescue StandardError => e
            failures[name] = ErrorMap.map(e)
          end

          return check(PASS, "#{count(names.size, 'datasource')} (#{names.join(', ')}); VaultKit connected to " \
                             "each and read its schema.") if failures.empty?

          broken = failures.map { |name, f| "#{name}: #{f[:message]} (#{f[:code]})" }.join("; ")
          fix = failures.values.map { |f| f[:fix] }.uniq.join(" ")
          if @scans.empty?
            return check(FAIL, "VaultKit couldn't connect to any datasource. #{broken}", fix)
          end

          check(WARN, "Connected to #{@scans.keys.join(', ')}, but not to every datasource. #{broken}", fix)
        end

        # 5. The datasource's database role is safe (read-only, not a
        #    superuser or the table owner). The control plane can't tell yet.
        def datasource_role
          return Skip.new("No datasource could be reached.") if @scans.nil? || @scans.empty?

          check(WARN, "Not verified: VaultKit can't yet check which database role #{@scans.keys.join(', ')} " \
                      "#{@scans.size == 1 ? 'connects' : 'connect'} as (#{ROLE_SAFETY_ISSUE}).",
                "Use a dedicated read-only role, not a superuser or the table owner. See #{ROLE_SAFETY_ISSUE}")
        end

        # 6. Each reachable datasource's schema is in the registry, current,
        #    and classified.
        def schema
          return Skip.new("No datasource could be reached.") if @scans.nil? || @scans.empty?

          registry = @client.get(org_path("/registries/export"))
          registry = {} unless registry.is_a?(Hash)

          unscanned = []
          drifted = []
          unknown = []
          datasets = 0
          columns = 0

          @scans.each do |name, scan|
            entries = registry.select { |_, d| d.is_a?(Hash) && d["datasource"] == name }
            if entries.empty?
              unscanned << name
              next
            end

            datasets += entries.size
            entries.each do |dataset, d|
              (d["fields"] || {}).each do |field, f|
                columns += 1
                unknown << "#{dataset}.#{field}" if f["sensitivity"].to_s.empty? || f["sensitivity"] == "unknown"
              end
            end

            Array(scan.dig("diff", "datasets")).each do |d|
              drifted << "#{name}/#{d['name']}" if (d["changes"] || {}).values.any? { |v| Array(v).any? }
              Array(d["unreviewed"]).each { |f| unknown << "#{d['name']}.#{f}" }
            end
          end
          unknown.uniq!

          if unscanned.any?
            return check(FAIL, "#{unscanned.join(', ')} #{unscanned.size == 1 ? 'has' : 'have'} never been scanned " \
                               "into the registry, so policies can't see #{unscanned.size == 1 ? 'its' : 'their'} " \
                               "columns.",
                         unscanned.map { |n| "vkit scan #{n} --mode apply" }.join("; ") +
                           "; then vkit registry export, review datasets/registry.yaml, and commit it.")
          end

          problems = []
          fixes = []
          if drifted.any?
            problems << "the schema changed since the last applied scan (#{list(drifted)})"
            fixes << "Review the changes with `vkit scan <datasource>`, then `vkit scan <datasource> --mode apply` " \
                     "and `vkit registry export`."
          end
          if unknown.any?
            problems << "#{count(unknown.size, 'column')} #{unknown.size == 1 ? 'has' : 'have'} no classification " \
                        "(#{list(unknown)})"
            fixes << "Set each one's sensitivity in datasets/registry.yaml, then " \
                     "`vkit policy bundle && vkit policy deploy`."
          end
          summary = "#{count(datasets, 'dataset')}, #{count(columns, 'column')} in the registry"
          return check(WARN, "#{summary}, but #{problems.join('; and ')}.", fixes.join(" ")) if problems.any?

          check(PASS, "#{summary}, all classified; the schema matches the last scan.")
        end

        # 7. A bundle is active, and it's what `vkit policy bundle` would
        #    build from this repository's HEAD. Bundle versions are the
        #    commit the policies were bundled from (vaultkitcli#58), so the
        #    active one matches when it's HEAD, or an earlier commit whose
        #    policies, registry and pack list are the same as HEAD's.
        #    Nothing is compiled or written, and a dirty tree doesn't matter:
        #    the comparison is between commits.
        def policy_bundle
          version = active_bundle_version
          if version.nil?
            return check(FAIL, "No policy bundle is active in #{@org}, so no request is allowed.",
                         "vkit policy bundle && vkit policy deploy")
          end

          shown = short(version)
          git = Vkit::Policy::GitState.new(@project_root)
          unless Dir.exist?(File.join(@project_root, "config/policies"))
            return check(WARN, "#{shown} is active. This isn't a VaultKit policy project, so it wasn't compared " \
                               "with your policies.",
                         "Run `vkit doctor` from the policy project's folder to compare.")
          end

          head = git.repo? ? git.head : nil
          unless head
            return check(WARN, "#{shown} is active. This policy project has no git commits, so it couldn't be " \
                               "compared.",
                         "Commit the project, then `vkit policy bundle && vkit policy deploy`.")
          end

          note = uncommitted_note(git)
          if version == head
            return check(PASS, "#{shown} is active: this repository's HEAD.#{note}")
          end

          unless git.commit?(version)
            return check(WARN, "#{shown} is active, but it isn't a commit in this repository (named with --version, " \
                               "or bundled from another clone or an unfetched branch), so it couldn't be compared " \
                               "with HEAD (#{short(head)}).#{note}",
                         "git fetch, or deploy from here: vkit policy bundle && vkit policy deploy")
          end

          unless git.changed_between?(version, head, BUNDLE_INPUTS)
            return check(PASS, "#{shown} is active; HEAD (#{short(head)}) has the same policies and registry.#{note}")
          end

          behind = git.commits_between(version, head)
          check(FAIL, "#{shown} is active, but the policies or registry changed after it" \
                      "#{behind&.positive? ? " (HEAD is #{count(behind, 'commit')} ahead)" : ''}; HEAD " \
                      "(#{short(head)}) isn't deployed.#{note}",
                "vkit policy bundle && vkit policy deploy")
        end

        # The active bundle's version: GET /approval_groups names it for any
        # member; GET /setup (admins) is asked only if that fails.
        def active_bundle_version
          groups = begin
            approval_groups
          rescue StandardError
            nil
          end
          return groups["policy_bundle_version"] if groups.is_a?(Hash) && groups.key?("policy_bundle_version")

          setup = @client.get(org_path("/setup"))
          setup.is_a?(Hash) ? setup.dig("active_policy", "version") : nil
        end

        def uncommitted_note(git)
          changed = git.uncommitted(BUNDLE_INPUTS)
          return "" if changed.empty?

          " Uncommitted changes (#{list(changed.map { |c| c[:path] })}) aren't in any bundle yet."
        rescue StandardError
          ""
        end

        # 7b. Who approves each approval group's requests. A group nobody is
        #     in falls back to org admins (vaultkit#123), which is fine to
        #     know but not a problem; only an unreadable list fails.
        def approval_groups
          return @approval_groups if defined?(@approval_groups)

          @approval_groups = @client.get(org_path("/approval_groups"))
        rescue StandardError => e
          @approval_groups_error = e
          @approval_groups = nil
          raise
        end

        def approval_routing
          raise @approval_groups_error if @approval_groups_error

          groups = Array((approval_groups || {})["groups"])
          return check(PASS, "No policy routes requests to an approval group.") if groups.empty?

          described = []
          notes = []
          unrouted = []
          groups.each do |g|
            name = g["name"].to_s
            members = (g.key?("active_member_count") ? g["active_member_count"] : g["member_count"]).to_i
            described << "#{name} (#{count(members, 'member')})"
            if g["admin_fallback"] == true
              notes << "#{name} has no members, so org admins approve its requests."
            elsif !g.key?("admin_fallback") && members.zero? && g["policy_count"].to_i.positive?
              unrouted << name
            end
          end

          detail = "#{count(groups.size, 'group')}: #{described.join(', ')}."
          detail += " #{notes.join(' ')}" if notes.any?
          if unrouted.any?
            return check(WARN, "#{detail} #{unrouted.join(', ')} #{unrouted.size == 1 ? 'has' : 'have'} no members, " \
                               "and this control plane doesn't say who approves #{unrouted.size == 1 ? 'its' : 'their'}" \
                               " requests.",
                         "Add someone to #{unrouted.join(', ')} in the console (Team), or upgrade the control plane.")
          end

          check(PASS, detail)
        end

        # 8. The agent's own credentials, as the SDK and vaultkit-mcp read
        #    them, work; and vkit itself isn't running as the agent. Tokens
        #    are never printed, nor any part of one.
        def agent_token
          Output.register_secret(@env["VAULTKIT_TOKEN"])
          Output.register_secret(@env["VKIT_TOKEN"])

          problems = []
          fixes = []
          if vkit_token_is_agent?
            problems << "VKIT_TOKEN is an agent token, so every vkit command runs as the agent"
            fixes << "Unset VKIT_TOKEN (and VKIT_ENDPOINT) and use VAULTKIT_TOKEN for the agent."
          end

          missing = AGENT_ENV.select { |k| @env[k].to_s.strip.empty? }
          if missing.any?
            problems << "#{missing.join(', ')} #{missing.size == 1 ? "isn't" : "aren't"} set"
            fixes << "Create a token with `vkit agents tokens create --name <agent> --secret-file <path>`, and set " \
                     "VAULTKIT_BASE_URL, VAULTKIT_ORG and VAULTKIT_TOKEN (the file's contents) in the agent's " \
                     "environment (for an MCP host, its server config's env block)."
            return check(FAIL, "#{problems.join('; ')}.", fixes.join(" "))
          end

          base = @env["VAULTKIT_BASE_URL"].strip.chomp("/")
          org = @env["VAULTKIT_ORG"].strip
          agent = @client_for.call(base, @env["VAULTKIT_TOKEN"].strip)
          me = begin
            agent.get("/auth/whoami")
          rescue StandardError => e
            mapped = ErrorMap.map(e)
            problems << "VAULTKIT_TOKEN didn't work at #{base}: #{mapped[:message]}"
            fixes << (mapped[:code] == "control_plane_unreachable" ? "Check VAULTKIT_BASE_URL." : agent_token_fix)
            return check(FAIL, "#{problems.join('; ')}.", fixes.join(" "))
          end

          if me["type"] != "agent"
            problems << "VAULTKIT_TOKEN is a person's login, not an agent token: the agent would act as them " \
                        "and stop working within the hour"
            fixes << agent_token_fix
            return check(FAIL, "#{problems.join('; ')}.", fixes.join(" "))
          end

          name = me.dig("agent", "name")
          visible = begin
            Array(agent.get("/api/v1/orgs/#{org}/aql/datasets")["datasets"]).size
          rescue API::APIError => e
            raise unless e.status == 404

            problems << "VAULTKIT_ORG (#{org}) isn't the organization agent #{name}'s token belongs to"
            fixes << "Set VAULTKIT_ORG to the token's organization slug."
            return check(FAIL, "#{problems.join('; ')}.", fixes.join(" "))
          end

          return check(FAIL, "#{problems.join('; ')}.", fixes.join(" ")) if problems.any?

          check(PASS, "Agent #{name} (#{me.dig('agent', 'role')}) is set up for #{org} at #{base}, and can see " \
                      "#{count(visible, 'dataset')}.")
        end

        def agent_token_fix
          "Create an agent token with `vkit agents tokens create --name <agent> --secret-file <path>` and put " \
            "its contents in VAULTKIT_TOKEN."
        end

        # VKIT_TOKEN set to an agent token: the same value as VAULTKIT_TOKEN,
        # or one the control plane says is an agent's.
        def vkit_token_is_agent?
          token = @env["VKIT_TOKEN"].to_s.strip
          return false if token.empty?
          return true if token == @env["VAULTKIT_TOKEN"].to_s.strip

          base = [@env["VKIT_ENDPOINT"], @env["VAULTKIT_BASE_URL"], @endpoint].map { |v| v.to_s.strip }
                                                                              .find { |v| !v.empty? }
          return false unless base

          @client_for.call(base.chomp("/"), token).get("/auth/whoami")["type"] == "agent"
        rescue StandardError
          false
        end

        # 9. Optional: the Python SDK's MCP server starts with the agent's
        #    environment and lists VaultKit's tools.
        def mcp_server
          command = @which.call("vaultkit-mcp")
          unless command
            return Skip.new("Optional: vaultkit-mcp (the Python SDK's MCP server) isn't installed.",
                            "pip install 'vaultkit[mcp]' to give an MCP host (Claude, Cursor) VaultKit's tools.")
          end

          tools = @mcp_probe.call(command, @env)
          missing = MCP_TOOLS - tools
          if missing.any?
            return check(FAIL, "vaultkit-mcp started but doesn't list #{missing.join(', ')} " \
                               "(it lists: #{tools.empty? ? 'nothing' : tools.join(', ')}).",
                         "pip install --upgrade 'vaultkit[mcp]'")
          end

          check(PASS, "vaultkit-mcp (#{command}) starts and lists #{MCP_TOOLS.join(', ')}.")
        rescue McpProbe::Failed => e
          check(FAIL, "vaultkit-mcp didn't start: #{e.message}",
                "Run vaultkit-mcp in a terminal with the same VAULTKIT_* variables to see why; " \
                "pip install --upgrade 'vaultkit[mcp]' if it's out of date.")
        end

        def org_path(suffix)
          "/api/v1/orgs/#{@org}#{suffix}"
        end

        # A login JWT's exp claim (read, not verified: the control plane
        # verifies it). nil for anything that isn't a JWT.
        def jwt_expiry(token)
          payload = token.to_s.split(".")[1]
          return nil unless payload

          exp = JSON.parse(Base64.urlsafe_decode64(payload + "=" * (-payload.length % 4)))["exp"]
          exp.is_a?(Numeric) ? Time.at(exp) : nil
        rescue ArgumentError, JSON::ParserError
          nil
        end

        def parse_time(value)
          value && Time.parse(value.to_s)
        rescue ArgumentError
          nil
        end

        def duration(seconds)
          minutes = (seconds.abs / 60).round
          text = minutes < 90 ? count(minutes, "minute") : format("%g hours", (minutes / 60.0).round(1))
          seconds.negative? ? "#{text} ago" : "in #{text}"
        end

        def short(version)
          version.to_s.match?(/\A\h{40}\z/) ? version[0, 12] : version.to_s
        end

        def count(n, noun)
          "#{n} #{noun}#{'s' unless n == 1}"
        end

        def list(items, max = 5)
          return items.join(", ") if items.size <= max

          "#{items.first(max).join(', ')} and #{items.size - max} more"
        end

        def find_executable(cmd)
          @env.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
            path = File.join(dir, cmd)
            return path if File.file?(path) && File.executable?(path)
          end
          nil
        end
      end
    end
  end
end

require "thor"
require_relative "commands/login_command"
require_relative "commands/request_command"
require_relative "commands/requests_list_command"
require_relative "commands/approval_command"
require_relative "commands/fetch_command"
require_relative "commands/datasource_command"
require_relative "commands/scan_command"
require_relative "commands/policy_bundle_command"
require_relative "commands/policy_validate_command"
require_relative "commands/policy_deploy_command"
require_relative "requests_cli"

module Vkit
  module CLI
    class BaseCLI < Thor
      def self.exit_on_failure?
        true
      end

      # ------------ LOGIN -------------
      desc "login", "Authenticate with VaultKit auth server"
      option :server, type: :string, default: ENV["VKIT_AUTH_URL"] || "http://localhost:3000"
      option :email,  type: :string, desc: "Email for login"
      def login
        server = options[:server]
        email  = options[:email]
        Commands::LoginCommand.new(server: server, email: email).call
      end

      desc "whoami", "Show current identity"
      def whoami
        Commands::LoginCommand.new(server: nil).call_whoami
      end

      desc "logout", "Clear stored credentials"
      def logout
        Commands::LoginCommand.new(server: nil).call_logout
      end

      # ------------ REQUEST -------------
      desc "request", "Send an inline JSON AQL request (use --aql or pipe via STDIN)"
      option :aql, type: :string, desc: "AQL JSON payload (inline)"
      option :env, type: :string, default: "production"
      option :requester_region, type: :string
      option :dataset_region, type: :string
      option :requester_clearance, type: :string, desc: "Clearance level (low/high/admin)"
      option :format, type: :string, default: "table", enum: %w[json table], desc: "Output format"
      def request
        aql_str = options[:aql]
        Commands::RequestCommand
          .new(api_url: ENV["VKIT_API_URL"])
          .call(aql_str, options)
      end

      desc "requests SUBCOMMAND ...ARGS", "Manage request history"
      subcommand "requests", Vkit::CLI::RequestsCLI    

      # ------------ APPROVALS -------------
      desc "approval:list", "List all pending approval requests"
      option :state, type: :string, default: "pending", enum: %w[pending approved denied all]
      define_method("approval:list") do
        Commands::ApprovalCommand.new.call_list(state: options[:state])
      end

      desc "approval:approve ID", "Approve a pending request"
      option :ttl, type: :numeric, default: 3600, desc: "Grant TTL in seconds (default: 3600)"
      define_method("approval:approve") do |id|
        Commands::ApprovalCommand.new.call_approve(
          id: id,
          ttl_seconds: options[:ttl]
        )
      end

      desc "approval:deny ID", "Deny a pending request"
      option :reason,   type: :string, desc: "Reason for denial (if omitted, will prompt)"
      define_method("approval:deny") do |id|
        Commands::ApprovalCommand.new.call_deny(
          id: id,
          reason: options[:reason]
        )
      end

      desc "fetch --grant ID", "Fetch data from Funl using a valid grant"
      option :grant, type: :string, required: true
      option :format, type: :string, default: "json", enum: %w[json table]
      def fetch
        grant_id = options[:grant]
        format   = options[:format]

        Commands::FetchCommand.new(api_url: ENV["VKIT_API_URL"]).call(grant_ref: grant_id, format: format)
      end

      desc "datasource SUBCOMMAND ...ARGS", "Manage datasources (admin only)"
      subcommand "datasource", Class.new(Thor) {

        # ADD
        desc "add", "Add a new datasource (admin only)"
        option :id,       required: true,  desc: "Unique datasource ID (e.g. primary_pg)"
        option :engine,   required: true,  desc: "Database engine (postgres, mysql, snowflake, etc.)"
        option :username, required: true,  desc: "Username for connecting to the datasource"
        option :password, required: true,  desc: "Password for the datasource user"
        option :config,   required: true,  desc: "JSON connection config: {\"host\":\"...\",\"port\":5432,\"database\":\"analytics\"}"

        def add
          Commands::DatasourceCommand.new.add(
            id: options[:id],
            engine: options[:engine],
            username: options[:username],
            password: options[:password],
            config: options[:config]
          )
        end

        # LIST
        desc "list", "List all datasources (admin only)"
        def list
          Commands::DatasourceCommand.new.list
        end

        # GET
        desc "get ID", "Fetch a datasource by ID (admin only)"
        def get(id)
          Commands::DatasourceCommand.new.get(id)
        end
      }

      desc "scan DATASOURCE", "Scan datasource and diff against registry"
      option :mode, type: :string, default: "diff_only", enum: %w[diff_only apply]
      def scan(datasource)
        Commands::ScanCommand
          .new(api_url: ENV["VKIT_API_URL"])
          .call(datasource, mode: options[:mode])
      end

      desc "policy SUBCOMMAND ...ARGS", "Manage policy bundles"
      subcommand "policy", Class.new(Thor) {
        desc "bundle", "Compile YAML policies into a JSON policy bundle"
        option :policies_dir, type: :string, default: "config/policies"
        option :registry_dir, type: :string, default: "config"
        option :out, type: :string, default: "dist/policy_bundle.json"
        option :org, type: :string, desc: "Organization slug"
        option :version, type: :string, desc: "Bundle version (default: git SHA)"

        def bundle
          Commands::PolicyBundleCommand.new.call(
            policies_dir: options[:policies_dir],
            registry_dir: options[:registry_dir],
            out: options[:out],
            org: options[:org],
            version: options[:version]
          )
        end

        desc "validate", "Validate a compiled policy bundle"
        option :bundle, type: :string, default: "dist/policy_bundle.json"
        option :schema, type: :string, desc: "Path to schema (optional)"

        def validate
          Commands::PolicyValidateCommand.new.call(
            bundle_path: options[:bundle],
            schema_path: options[:schema]
          )
        end

        desc "deploy", "Deploy a policy bundle to VaultKit"
        option :bundle, type: :string, default: "dist/policy_bundle.json"
        option :org, type: :string, required: true
        option :server, type: :string, default: ENV["VKIT_API_URL"] || "http://localhost:3000"
        option :activate, type: :boolean, default: true

        def deploy
          Commands::PolicyDeployCommand.new.call(
            bundle_path: options[:bundle],
            org: options[:org],
            server: options[:server],
            activate: options[:activate]
          )
        end
      }
    end
  end
end

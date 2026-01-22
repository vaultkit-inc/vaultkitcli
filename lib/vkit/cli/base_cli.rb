# frozen_string_literal: true

require "thor"
require_relative "requests_cli"

module Vkit
  module CLI
    class BaseCLI < Thor
      def self.exit_on_failure?
        true
      end

      # LOGIN
      desc "login", "Authenticate with VaultKit control plane"
      option :endpoint, type: :string
      option :email, type: :string
      def login
        Commands::LoginCommand.new(
          endpoint: options[:endpoint],
          email: options[:email]
        ).call
      end

      desc "whoami", "Show current identity"
      def whoami
        Commands::WhoamiCommand.new.call
      end

      desc "logout", "Clear stored credentials"
      def logout
        Commands::LogoutCommand.new.call
      end

      # REQUEST
      desc "request", "Send an inline JSON AQL request (use --aql or pipe via STDIN)"
      option :aql, type: :string, desc: "AQL JSON payload (inline)"
      option :env, type: :string, default: "production"
      option :requester_region, type: :string
      option :dataset_region, type: :string
      option :requester_clearance, type: :string, desc: "Clearance level (low/high/admin)"
      option :format, type: :string, default: "table", enum: %w[json table]
      def request
        Commands::RequestCommand.new.call(options[:aql], options)
      end

      desc "requests SUBCOMMAND ...ARGS", "Manage request history"
      subcommand "requests", Vkit::CLI::RequestsCLI

      # APPROVALS
      desc "approval:list", "List all approval requests"
      option :state, type: :string, default: "pending", enum: %w[pending approved denied all]
      define_method("approval:list") do
        Commands::ApprovalCommand.new.call_list(state: options[:state])
      end

      desc "approval:approve ID", "Approve a pending request"
      option :ttl, type: :numeric, default: 3600
      define_method("approval:approve") do |id|
        Commands::ApprovalCommand.new.call_approve(
          id: id,
          ttl_seconds: options[:ttl]
        )
      end

      desc "approval:deny ID", "Deny a pending request"
      option :reason, type: :string
      define_method("approval:deny") do |id|
        Commands::ApprovalCommand.new.call_deny(
          id: id,
          reason: options[:reason]
        )
      end

      # FETCH
      desc "fetch --grant ID", "Fetch data from Funl using a valid grant"
      option :grant, type: :string, required: true
      option :format, type: :string, default: "json", enum: %w[json table]
      def fetch
        Commands::FetchCommand.new.call(
          grant_ref: options[:grant],
          format: options[:format]
        )
      end

      # DATASOURCE
      desc "datasource SUBCOMMAND ...ARGS", "Manage datasources (admin only)"
      subcommand "datasource", Class.new(Thor) {
        desc "add", "Add a new datasource (admin only)"
        option :id, required: true
        option :engine, required: true
        option :username, required: true
        option :password, required: true
        option :config, required: true

        def add
          Commands::DatasourceCommand.new.add(
            id: options[:id],
            engine: options[:engine],
            username: options[:username],
            password: options[:password],
            config: options[:config]
          )
        end

        desc "list", "List all datasources (admin only)"
        def list
          Commands::DatasourceCommand.new.list
        end

        desc "get ID", "Fetch a datasource by ID (admin only)"
        def get(id)
          Commands::DatasourceCommand.new.get(id)
        end
      }

      # SCAN
      desc "scan DATASOURCE", "Scan datasource and diff against registry"
      option :mode, type: :string, default: "diff_only", enum: %w[diff_only apply]
      def scan(datasource)
        Commands::ScanCommand.new.call(
          datasource,
          mode: options[:mode]
        )
      end

      # POLICY
      desc "policy SUBCOMMAND ...ARGS", "Manage policy bundles"
      subcommand "policy", Class.new(Thor) {

        desc "bundle", "Compile YAML policies into a JSON policy bundle"
        option :policies_dir, type: :string, default: "config/policies"
        option :registry_dir, type: :string, default: "config"
        option :out, type: :string, default: "dist/policy_bundle.json"
        option :org, type: :string
        option :version, type: :string

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
        option :schema, type: :string

        def validate
          Commands::PolicyValidateCommand.new.call(
            bundle_path: options[:bundle],
            schema_path: options[:schema]
          )
        end

        desc "deploy", "Deploy a policy bundle to VaultKit"
        option :bundle, type: :string, default: "dist/policy_bundle.json"
        option :org, type: :string
        option :activate, type: :boolean, default: true

        def deploy
          Commands::PolicyDeployCommand.new.call(
            bundle_path: options[:bundle],
            org: options[:org],
            activate: options[:activate]
          )
        end
      }

      desc "agents SUBCOMMAND ...ARGS", "Manage agents and automation identities"
      subcommand "agents", Class.new(Thor) {

        # agents tokens SUBCOMMAND
        desc "tokens SUBCOMMAND ...ARGS", "Manage agent tokens"
        subcommand "tokens", Class.new(Thor) {

          # agents tokens list
          desc "list", "List tokens for an agent"
          option :format, type: :string, default: "table", enum: %w[table json]
          def list
            Commands::AgentTokensListCommand.new.call(
              agent: options[:agent],
              format: options[:format]
            )
          end

          # agents tokens create
          desc "create", "Create a new agent token (automation identity)"
          option :name, required: true, desc: "Human-readable name (e.g. billing-bot)"
          option :expires_in, type: :string, desc: "Token lifetime (e.g. 1h, 24h, 30d)"
          option :role, type: :string, default: "agent", desc: "Role assigned to this token"
          def create
            Commands::AgentTokensCreateCommand.new.call(
              name: options[:name],
              expires_in: options[:expires_in],
              role: options[:role]
            )
          end

          # agents tokens revoke
          desc "revoke", "Revoke an agent token"
          option :token, required: true, desc: "Token ID or prefix"
          option :force, type: :boolean, default: false, desc: "Skip confirmation"
          def revoke
            Commands::AgentTokensRevokeCommand.new.call(
              token: options[:token],
              force: options[:force]
            )
          end
        }
      }
    end
  end
end

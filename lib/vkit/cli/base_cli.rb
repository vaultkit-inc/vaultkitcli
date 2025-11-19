require "thor"
require_relative "commands/login_command"
require_relative "commands/request_command"
require_relative "commands/approval_command"
require_relative "commands/fetch_command"
require_relative "commands/datasource_command"

module Vkit
  module CLI
    class BaseCLI < Thor
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
      option :policies_dir, type: :string, default: "config/policies"
      option :registry, type: :string, default: "datasets/registry.yaml"
      option :funl_url, type: :string, default: ENV["FUNL_URL"] || "http://localhost:8080"
      option :requester_clearance, type: :string, desc: "Clearance level (low/high/admin)"
      option :format, type: :string, default: "json", enum: %w[json table], desc: "Output format"
      def request
        aql_str = options[:aql]
        funl_url = options[:funl_url]
        Commands::RequestCommand.new(funl_url: funl_url).call(aql_str, options)
      end

      desc "request:list", "List your past data access requests"
      define_method("request:list") do
        Commands::RequestCommand.new(funl_url: nil).call_list
      end

      desc "request:show ID", "Show details of a specific request you created"
      define_method("request:show") do |id|
        Commands::RequestCommand.new(funl_url: nil).call_show(id)
      end

      # ------------ APPROVALS -------------
      desc "approval:list", "List all pending approval requests"
      option :state, type: :string, default: "pending", enum: %w[pending approved denied all]
      define_method("approval:list") do
        Commands::ApprovalCommand.new.call_list(state: options[:state])
      end

      desc "approval:approve ID", "Approve a pending request"
      option :approver, type: :string, desc: "Override approver email (optional)"
      option :ttl, type: :numeric, default: 3600, desc: "Grant TTL in seconds (default: 3600)"
      define_method("approval:approve") do |id|
        Commands::ApprovalCommand.new.call_approve(
          id: id,
          approver: options[:approver],
          ttl_seconds: options[:ttl]
        )
      end

      desc "approval:deny ID", "Deny a pending request"
      option :approver, type: :string, desc: "Override approver email (optional)"
      option :reason,   type: :string, desc: "Reason for denial (if omitted, will prompt)"
      define_method("approval:deny") do |id|
        Commands::ApprovalCommand.new.call_deny(
          id: id,
          approver: options[:approver],
          reason: options[:reason]
        )
      end

      desc "fetch --grant ID", "Fetch data from Funl using a valid grant"
      option :grant, type: :string, required: true
      option :format, type: :string, default: "json", enum: %w[json table]
      option :funl_url, type: :string, default: ENV["FUNL_URL"] || "https://kizzie-unfretting-lastly.ngrok-free.dev"
      def fetch
        grant_id = options[:grant]
        format   = options[:format]
        funl_url = options[:funl_url]

        Commands::FetchCommand.new(funl_url: funl_url).call(grant_id: grant_id, format: format)
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
    end
  end
end

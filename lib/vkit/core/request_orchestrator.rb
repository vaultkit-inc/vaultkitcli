require "json"
require "yaml"
require_relative "policy_engine"
require_relative "approval_store"
require_relative "funl_client"
require_relative "credential_store"
require_relative "masking"
require_relative "grant_store"
require_relative "dataset_registry"

module Vkit
  module Core
    class RequestOrchestrator
      def initialize(policies_dir:, registry_path:, funl_url:)
        @policies_dir  = policies_dir
        @registry_path = registry_path
        @funl_url      = funl_url
      end

      def run_inline(aql_json:, options: {})
        # 1) Authenticate user
        creds   = Vkit::Core::CredentialStore.new
        token   = creds.load_token
        user    = creds.load_user
        raise "Not logged in. Run: vkit login" if token.nil? || user.nil?

        # 2) Load registry and policy engine
        registry = YAML.load_file(@registry_path)
        engine   = Vkit::Core::PolicyEngine.new(policy_dir: @policies_dir, registry: registry)
        grant_store = Vkit::Core::GrantStore.new

        # 3) Parse AQL
        aql = JSON.parse(aql_json)
        dataset = (aql["source_table"] || aql["dataset"]).to_s
        raise "AQL missing source_table/dataset" if dataset.empty?

        fields = extract_fields(aql)

        # 4) Build request context
        req_ctx = {
          dataset: dataset,
          fields: fields,
          requester_role: user["role"],
          requester_clearance: options[:requester_clearance] || user["clearance"],
          requester: user["email"],
          requester_region: options[:requester_region],
          dataset_region: options[:dataset_region],
          environment: options[:environment] || "production",
          time: Time.now
        }

        # 5) Check for existing valid grant
        if (grant = grant_store.find_valid(request: req_ctx))
          puts "🔑 Reusing valid grant #{grant[:id]} (expires #{grant[:expires_at]})"
          client = Vkit::Core::FunlClient.new(base_url: @funl_url)
          rows = client.execute(
            aql: aql,
            bearer: token,
            options: { session_token: grant[:session_token] }
          )
          return { status: :ok, reused: true, rows: rows, grant_id: grant[:id], expires_at: grant[:expires_at] }
        end

        # 6) Evaluate policies
        decision = engine.evaluate(req_ctx)

        case decision[:action]
        when "deny"
          { status: :denied, policy_id: decision[:policy_id], reason: decision[:reason] || "Denied by policy" }

        when "require_approval"
          queue = Vkit::Core::ApprovalStore.new
          req_id = queue.enqueue(
            { dataset: dataset, fields: fields, requester: user["email"] },
            reason: decision[:reason] || "Approval required",
            approver_role: decision[:approver_role] || "approver"
          )

          return {
            status: :queued,
            request_id: req_id,
            approver_role: decision[:approver_role],
            reason: decision[:reason],
            state: "pending"
          }

        when "mask", "allow"
          ttl = decision[:ttl] || 3600
          grant = grant_store.issue!(
            request: req_ctx,
            decision: decision[:action],
            policy_id: decision[:policy_id],
            reason: decision[:reason],
            ttl_seconds: ttl
          )

          mask_fields = decision[:action] == "mask" ?
                          Vkit::Core::Masking.mask_fields(
                            dataset: req_ctx[:dataset],
                            requested_fields: req_ctx[:fields],
                            registry: registry
                          ) : []

          # client = Vkit::Core::FunlClient.new(base_url: @funl_url)
          # rows = client.execute(
          #   aql: aql,
          #   bearer: token,
          #   options: { mask_fields: mask_fields, session_token: grant[:session_token] }
          # )
          # { status: :ok, rows: rows, grant_id: grant[:id], expires_at: grant[:expires_at] }

          grant_store.update_mask_fields!(grant[:id], mask_fields)

          {
            status: :granted,
            grant_id: grant[:id],
            session_token: grant[:session_token],
            expires_at: grant[:expires_at],
            masked_fields: mask_fields
          }
        else
          raise "Unknown decision: #{decision.inspect}"
        end
      end

      private

      def extract_fields(aql)
        fields = []
        (aql["columns"] || []).each { |c| fields << strip_table_prefix(c.to_s) }
        (aql["aggregates"] || []).each { |agg| fields << strip_table_prefix(agg["field"].to_s) if agg["field"] }
        fields.uniq
      end

      def strip_table_prefix(fq)
        fq.include?(".") ? fq.split(".", 2).last : fq
      end
    end
  end
end

require "json"
require "yaml"
require_relative "policy_engine"
require_relative "approval_store"
require_relative "funl_client"
require_relative "credential_store"
require_relative "masking"
require_relative "grant_store"
require_relative "dataset_registry"
require_relative "audit_logger"

module Vkit
  module Core
    class RequestOrchestrator
      def initialize(policies_dir:, registry_path:, funl_url:)
        @policies_dir  = policies_dir
        @registry_path = registry_path
        @funl_url      = funl_url
      end

      def run_inline(aql_json:, options: {})
        creds   = Vkit::Core::CredentialStore.new
        token   = creds.load_token
        user    = creds.load_user
        raise "Not logged in. Run: vkit login" if token.nil? || user.nil?

        registry = YAML.load_file(@registry_path)
        engine   = Vkit::Core::PolicyEngine.new(policy_dir: @policies_dir, registry: registry)
        grant_store = Vkit::Core::GrantStore.new

        aql = JSON.parse(aql_json)
        dataset = (aql["source_table"] || aql["dataset"]).to_s
        raise "AQL missing source_table/dataset" if dataset.empty?

        fields = extract_fields(aql)

        # Build request context
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

        # AUDIT: Request Received
        AuditLogger.log(
          event: "request.received",
          actor: user["email"],
          details: req_ctx
        )

        # Check for existing grant
        if (grant = grant_store.find_valid(request: req_ctx))
          AuditLogger.log(
            event: "grant.reused",
            actor: user["email"],
            details: {
              grant_id: grant[:id],
              dataset: dataset,
              fields: fields,
              expires_at: grant[:expires_at]
            }
          )

          client = Vkit::Core::FunlClient.new(base_url: @funl_url)
          rows = client.execute(
            aql: aql,
            bearer: token,
            options: { session_token: grant[:session_token] }
          )

          return {
            status: :ok,
            reused: true,
            rows: rows,
            grant_id: grant[:id],
            expires_at: grant[:expires_at]
          }
        end

        # Policy evaluation
        decision = engine.evaluate(req_ctx)

        AuditLogger.log(
          event: "policy.evaluated",
          actor: user["email"],
          details: decision.merge(dataset: dataset, fields: fields)
        )

        case decision[:action]
        when "deny"
          AuditLogger.log(
            event: "request.denied",
            actor: user["email"],
            details: {
              policy: decision[:policy_id],
              reason: decision[:reason],
              dataset: dataset,
              fields: fields
            }
          )

          return {
            status: :denied,
            policy_id: decision[:policy_id],
            reason: decision[:reason]
          }

        when "require_approval"
          queue = Vkit::Core::ApprovalStore.new
          req_id = queue.enqueue(
            { dataset: dataset, fields: fields, requester: user["email"] },
            reason: decision[:reason],
            approver_role: decision[:approver_role]
          )

          AuditLogger.log(
            event: "request.queued_for_approval",
            actor: user["email"],
            details: {
              request_id: req_id,
              approver_role: decision[:approver_role],
              reason: decision[:reason],
              dataset: dataset
            }
          )

          return {
            status: :queued,
            request_id: req_id,
            approver_role: decision[:approver_role],
            reason: decision[:reason]
          }

        when "allow", "mask"
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

          grant_store.update_mask_fields!(grant[:id], mask_fields)

          AuditLogger.log(
            event: "grant.issued",
            actor: user["email"],
            details: {
              grant_id: grant[:id],
              dataset: dataset,
              fields: fields,
              masked_fields: mask_fields,
              expires_at: grant[:expires_at],
              ttl: ttl
            }
          )

          return {
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

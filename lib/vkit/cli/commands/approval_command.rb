require_relative "../../core/approval_store"
require_relative "../../core/grant_store"
require_relative "../../core/credential_store"
require_relative "../../core/audit_logger"
require "yaml"

module Vkit
  module CLI
    module Commands
      class ApprovalCommand
        DEFAULT_TTL   = 3600
        REGISTRY_PATH = "datasets/registry.yaml"

        def initialize
          @approval_store = Vkit::Core::ApprovalStore.new
          @grant_store    = Vkit::Core::GrantStore.new
          @registry_cache = nil
        end

        # --------------------------------------------------
        # LIST — Scoped by user ability
        # --------------------------------------------------
        def call_list(state: "pending")
          user = current_user
          user_email = user["email"]
          user_role  = user["role"]

          Vkit::Core::AuditLogger.log(
            event: "approval.list.requested",
            actor: user_email,
            details: { state: state, role: user_role }
          )

          all = @approval_store.list(state: state)

          if all.empty?
            Vkit::Core::AuditLogger.log(
              event: "approval.list.empty",
              actor: user_email,
              details: { state: state }
            )
            puts empty_message_for(state, user_role)
            return
          end

          # Filter results based on role
          filtered =
            if ["admin", "approver"].include?(user_role)
              all
            else
              all.select do |req|
                can_user_approve?(user_role, req[:dataset], req[:approver_role]) &&
                  req[:requester] != user_email
              end
            end

          if filtered.empty?
            Vkit::Core::AuditLogger.log(
              event: "approval.list.no_scope",
              actor: user_email,
              details: { state: state, role: user_role }
            )
            puts no_scope_message(state, user_role)
            return
          end

          Vkit::Core::AuditLogger.log(
            event: "approval.list.returned",
            actor: user_email,
            details: { count: filtered.size, state: state }
          )

          puts "📋 Requests You Can Act On (#{filtered.size}, state=#{state}):"
          filtered.each do |r|
            puts "─" * 60
            puts "🆔  #{r[:id]}"
            puts "📂  Dataset:    #{r[:dataset]}"
            puts "📄  Fields:     #{r[:fields].join(', ')}"
            puts "👤  Requester:  #{r[:requester]}"
            puts "🔐  Required:   #{r[:approver_role] || 'n/a'}"
            puts "💬  Reason:     #{r[:reason]}"
          end
          puts "─" * 60
        end

        # --------------------------------------------------
        # APPROVE
        # --------------------------------------------------
        def call_approve(id:, approver:, ttl_seconds: DEFAULT_TTL)
          user, approver_email, approver_role = resolve_user_context(approver)

          Vkit::Core::AuditLogger.log(
            event: "approval.approve.initiated",
            actor: approver_email,
            details: { id: id, ttl: ttl_seconds }
          )

          pending = fetch(id)

          if pending[:requester] == user["email"]
            raise "You cannot approve your own request (#{pending[:id]})."
          end

          ensure_authorized!(approver_role, pending[:dataset], pending[:approver_role])

          grant = @approval_store.approve!(
            id,
            approver: approver_email,
            ttl_seconds: ttl_seconds
          )

          Vkit::Core::AuditLogger.log(
            event: "approval.approved",
            actor: approver_email,
            details: {
              request_id: id,
              dataset: pending[:dataset],
              fields: pending[:fields],
              grant_id: grant[:id],
              expires_at: grant[:expires_at]
            }
          )

          puts "✅ Approved request #{id}"
          puts "   → Grant ID: #{grant[:id]}"
          puts "   → Expires at: #{grant[:expires_at]}"
          puts "   → Approved by: #{approver_email} (role: #{approver_role})"

        rescue => e
          Vkit::Core::AuditLogger.log(
            event: "approval.approve.failed",
            actor: approver_email,
            details: { id: id, error: e.message }
          )
          puts "❌ Approval failed: #{e.message}"
          exit 1
        end

        # --------------------------------------------------
        # DENY
        # --------------------------------------------------
        def call_deny(id:, approver:, reason: nil)
          user, approver_email, approver_role = resolve_user_context(approver)

          Vkit::Core::AuditLogger.log(
            event: "approval.deny.initiated",
            actor: approver_email,
            details: { id: id }
          )

          pending = fetch(id)

          if pending[:requester] == user["email"]
            raise "You cannot deny your own request (#{pending[:id]})."
          end

          ensure_authorized!(approver_role, pending[:dataset], pending[:approver_role])

          reason ||= prompt_reason
          raise "Denial reason cannot be empty" if reason.to_s.empty?

          @approval_store.deny!(id, approver: approver_email, reason: reason)

          Vkit::Core::AuditLogger.log(
            event: "approval.denied",
            actor: approver_email,
            details: {
              request_id: id,
              dataset: pending[:dataset],
              fields: pending[:fields],
              reason: reason
            }
          )

          puts "🚫 Denied request #{id}"
          puts "   → Denied by: #{approver_email} (role: #{approver_role})"
          puts "   → Reason: #{reason}"

        rescue => e
          Vkit::Core::AuditLogger.log(
            event: "approval.deny.failed",
            actor: approver_email,
            details: { id: id, error: e.message }
          )
          puts "❌ Deny failed: #{e.message}"
          exit 1
        end

        private
        # (helpers unchanged)
        # --------------------------------------------------
        def current_user
          creds = Vkit::Core::CredentialStore.new
          user = creds.load_user
          raise "Not logged in. Run: vkit login" if user.nil?
          user
        end

        def fetch(id)
          row = @approval_store.fetch(id)
          raise "Request not found" if row.nil?
          row
        end

        def resolve_user_context(override_email)
          user = current_user
          approver_email = override_email || user["email"]
          approver_role  = user["role"]
          [user, approver_email, approver_role]
        end

        def can_user_approve?(role, dataset, required_role)
          registry       = load_registry
          dataset_meta   = registry[dataset] || {}
          dataset_roles  = Array(dataset_meta["approvers"]).compact
          required_roles = Array(required_role).compact

          allowed_roles = (required_roles + dataset_roles + ["admin", "approver"]).uniq
          allowed_roles.include?(role)
        end

        def ensure_authorized!(role, dataset, required_role)
          unless can_user_approve?(role, dataset, required_role)
            raise "Not authorized: your role (#{role}) cannot act on dataset '#{dataset}'."
          end
        end

        def prompt_reason
          print "Enter reason for denial: "
          STDIN.gets&.strip
        end

        def load_registry
          @registry_cache ||= File.exist?(REGISTRY_PATH) ? YAML.load_file(REGISTRY_PATH) : {}
        end

        def empty_message_for(state, role)
          case state
          when "pending"  then "📭 No pending requests found."
          when "approved" then "📭 No approved requests found."
          when "denied"   then "📭 No denied requests found."
          else                "📭 No requests found."
          end
        end

        def no_scope_message(state, role)
          "🔒 You have no #{state} requests available for your role (#{role})."
        end
      end
    end
  end
end

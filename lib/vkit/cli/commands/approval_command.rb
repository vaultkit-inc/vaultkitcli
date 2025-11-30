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
        # LIST
        # --------------------------------------------------
        def call_list(state: "pending")
          user = current_user
          role = user["role"]
          email = user["email"]

          all = @approval_store.list(state: state)

          filtered =
            if ["admin", "approver"].include?(role)
              all
            else
              all.select do |req|
                can_user_approve?(role, req[:dataset], req[:approver_role]) &&
                  req[:requester] != email
              end
            end

          # AUDIT: list viewed
          Audit.log(
            event: "approval.list_viewed",
            actor: email,
            details: {
              state: state,
              role: role,
              total: all.size,
              scoped: filtered.size
            }
          )

          if filtered.empty?
            puts no_scope_message(state, role)
            return
          end

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
          pending = fetch(id)

          # AUDIT: Self-approve attempt
          if pending[:requester] == user["email"]
            Audit.log(
              event: "approval.unauthorized_self_approve_attempt",
              actor: user["email"],
              details: { request_id: id }
            )
            raise "You cannot approve your own request (#{pending[:id]})."
          end

          # AUDIT: Unauthorized role attempt
          unless can_user_approve?(approver_role, pending[:dataset], pending[:approver_role])
            Audit.log(
              event: "approval.unauthorized_role_attempt",
              actor: user["email"],
              details: {
                request_id: id,
                dataset: pending[:dataset],
                required_role: pending[:approver_role],
                actor_role: approver_role
              }
            )
            raise "Not authorized: your role (#{approver_role}) cannot act."
          end

          grant = @approval_store.approve!(id,
                                           approver: approver_email,
                                           ttl_seconds: ttl_seconds
          )

          # AUDIT: successful approval
          Audit.log(
            event: "approval.approved",
            actor: approver_email,
            details: {
              request_id: id,
              grant_id: grant[:id],
              expires_at: grant[:expires_at],
              role: approver_role
            }
          )

          puts "✅ Approved request #{id}"
          puts "   → Grant ID: #{grant[:id]}"
          puts "   → Expires at: #{grant[:expires_at]}"
        rescue => e
          puts "❌ Approval failed: #{e.message}"
          exit 1
        end

        # --------------------------------------------------
        # DENY
        # --------------------------------------------------
        def call_deny(id:, approver:, reason: nil)
          user, approver_email, approver_role = resolve_user_context(approver)
          pending = fetch(id)

          # AUDIT: self-deny attempt
          if pending[:requester] == user["email"]
            Audit.log(
              event: "approval.unauthorized_self_deny_attempt",
              actor: user["email"],
              details: { request_id: id }
            )
            raise "You cannot deny your own request (#{pending[:id]})."
          end

          # AUDIT: unauthorized deny attempt
          unless can_user_approve?(approver_role, pending[:dataset], pending[:approver_role])
            Audit.log(
              event: "approval.unauthorized_role_attempt",
              actor: user["email"],
              details: {
                request_id: id,
                dataset: pending[:dataset],
                required_role: pending[:approver_role],
                actor_role: approver_role
              }
            )
            raise "Not authorized."
          end

          reason ||= prompt_reason
          raise "Denial reason cannot be empty" if reason.to_s.empty?

          @approval_store.deny!(id, approver: approver_email, reason: reason)

          # AUDIT: denial
          Audit.log(
            event: "approval.denied",
            actor: approver_email,
            details: {
              request_id: id,
              reason: reason,
              role: approver_role
            }
          )

          puts "🚫 Denied request #{id}"
          puts "   → Denied by: #{approver_email}"
          puts "   → Reason: #{reason}"
        rescue => e
          puts "❌ Deny failed: #{e.message}"
          exit 1
        end
      end
    end
  end
end

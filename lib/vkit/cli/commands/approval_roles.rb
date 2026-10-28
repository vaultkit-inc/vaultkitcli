# frozen_string_literal: true

module Vkit
  module CLI
    module Commands
      # Approver roles as the control plane reports them. A request can need a
      # sign-off from several roles (approver_roles); outstanding_roles are the
      # ones still missing. Older control planes send only approver_role.
      module ApprovalRoles
        module_function

        def required_roles(approval)
          roles = Array(approval["approver_roles"])
          return roles if roles.any?

          approval["approver_role"].to_s.split(",").map(&:strip).reject(&:empty?)
        end

        def outstanding_roles(approval)
          return Array(approval["outstanding_roles"]) if approval.key?("outstanding_roles")

          approval["state"].to_s == "pending" ? required_roles(approval) : []
        end

        def describe(roles, fallback: "n/a")
          roles.empty? ? fallback : roles.join(", ")
        end
      end
    end
  end
end

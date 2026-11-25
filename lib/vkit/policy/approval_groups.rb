# frozen_string_literal: true

module Vkit
  module Policy
    # Approval group rules shared with the control plane
    # (User::RESERVED_GROUPS and PolicyApprovals::Staffing there):
    #
    # - Built-in role names can't be approval groups. Admins can already
    #   approve any request, and a group named admin would let its members
    #   approve as admins.
    # - A group nobody active is in doesn't stop a deploy, but warns: org
    #   admins approve its requests until someone is added.
    module ApprovalGroups
      RESERVED = %w[admin member approver agent].freeze
      WARNING_CODE = "approval_group_has_no_members"
      WARNING = "%<group>s has no members, so org admins will approve its requests until someone is added."

      module_function

      # Every group a compiled bundle's require_approval policies name, as
      # approver_role or in approver_roles, sorted.
      def named(bundle)
        Array(bundle["policies"]).flat_map do |policy|
          next [] unless policy["action"].to_s == "require_approval"

          approval = policy["approval"] || {}
          ([approval["approver_role"]] + Array(approval["approver_roles"])).map { |r| r.to_s.strip }
        end.reject(&:empty?).uniq.sort
      end

      # One warning per named group with no active members, given the
      # groups GET /approval_groups returns. Control planes from before
      # active_member_count send member_count, which counts active members.
      def warnings(bundle, groups)
        members = Array(groups).to_h do |g|
          [g["name"].to_s, (g.key?("active_member_count") ? g["active_member_count"] : g["member_count"]).to_i]
        end

        named(bundle).filter_map do |group|
          next if members.fetch(group, 0).positive?

          { "code" => WARNING_CODE, "group" => group, "message" => format(WARNING, group: group) }
        end
      end
    end
  end
end

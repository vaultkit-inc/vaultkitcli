require "yaml"
require_relative "matchers/time_window"
require_relative "ttl_parser"

module Vkit
  module Core
    class PolicyEngine
      PRIORITY = {
        "deny" => 3,
        "require_approval" => 2,
        "mask" => 1,
        "allow" => 0
      }.freeze

      def initialize(policy_dir:, registry:)
        @policies = load_policies(policy_dir)
        @registry = registry
      end

      def evaluate(request)
        decisions = @policies.map { |policy| evaluate_policy(policy, request) }
        decisions.max_by { |d| PRIORITY[d[:action]] } || allow_decision
      end

      private

      def load_policies(dir)
        Dir.glob(File.join(dir, "*.yaml")).map { |f| YAML.load_file(f) }
      end

      # ------------------------------------------------------------
      # Evaluate a single policy
      # ------------------------------------------------------------
      def evaluate_policy(policy, request)
        return allow_decision unless matches?(policy, request)

        action = policy["action"] || {}
        ttl = parse_ttl(action)

        # ---------------- DENY ---------------- #
        if action["deny"]
          return {
            action: "deny",
            policy_id: policy["id"],
            reason: action["reason"],
            ttl: ttl
          }
        end

        # ---------------- REQUIRE APPROVAL ---------------- #
        if action["require_approval"]
          return {
            action: "require_approval",
            policy_id: policy["id"],
            approver_role: action["approver_role"],
            reason: action["reason"],
            ttl: ttl
          }
        end

        # ---------------- MASK ---------------- #
        if action["mask"]
          return {
            action: "mask",
            policy_id: policy["id"],
            reason: action["reason"],
            ttl: ttl,
            mask_fields:   action["mask_fields"],
            mask_category: action["mask_category"],
            mask_except:   action["mask_except"]
          }
        end

        # ---------------- ALLOW ---------------- #
        if action["allow"] || action.empty?
          return allow_decision(ttl: ttl)
        end

        allow_decision(ttl: ttl)
      end

      def allow_decision(ttl: 3600)
        { action: "allow", ttl: ttl }
      end

      # ------------------------------------------------------------
      # Matching functions
      # ------------------------------------------------------------
      def matches?(policy, request)
        match_dataset(policy, request) &&
          match_fields(policy, request) &&
          match_context(policy, request)
      end

      def match_dataset(policy, request)
        return true unless policy.dig("match", "dataset")
        policy["match"]["dataset"].to_s == request[:dataset].to_s
      end

      def match_fields(policy, request)
        rule = policy.dig("match", "fields")
        return true unless rule

        requested_fields = request[:fields]
        field_meta = @registry.dig(request[:dataset], "fields") || {}

        # extract categories from registry (ex: "pii", "financial")
        requested_categories =
          requested_fields.map { |f| field_meta[f] }.compact

        # sensitivity: pii
        if rule["sensitivity"] && !requested_categories.include?(rule["sensitivity"])
          return false
        end

        # contains: ["pii", "financial"]
        if rule["contains"] && (rule["contains"] & requested_categories).empty?
          return false
        end

        # any: ["email", "name"]
        if rule["any"] && (requested_fields & rule["any"]).empty?
          return false
        end

        # all: ["email", "name"]
        if rule["all"] && !(rule["all"] - requested_fields).empty?
          return false
        end

        true
      end

      def match_context(policy, request)
        ctx = policy.dig("match", "context") || {}
        return true if ctx.empty?

        return false if ctx["requester_role"]      && ctx["requester_role"]      != request[:requester_role]
        return false if ctx["requester_clearance"] && ctx["requester_clearance"] != request[:requester_clearance]
        return false if ctx["requester_region"]    && ctx["requester_region"]    != request[:requester_region]
        return false if ctx["dataset_region"]      && ctx["dataset_region"]      != request[:dataset_region]
        return false if ctx["environment"]         && ctx["environment"]         != request[:environment]

        if time_rule = ctx["time"]
          return false unless Matchers::TimeWindow.matches?(time_rule, request[:time])
        end

        true
      end

      def parse_ttl(action)
        return Vkit::Core::TTLParser.parse(action["ttl"]) if action["ttl"]
        nil
      end
    end
  end
end

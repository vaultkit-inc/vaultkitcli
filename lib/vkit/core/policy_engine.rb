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

      # Evaluate a single policy
      def evaluate_policy(policy, request)
        return allow_decision unless matches?(policy, request)

        action = policy["action"] || {}
        ttl = parse_ttl(action)

        if action["deny"]
          return {
            action: "deny",
            policy_id: policy["id"],
            reason: action["reason"],
            ttl: ttl
          }
        end

        if action["require_approval"]
          return {
            action: "require_approval",
            policy_id: policy["id"],
            approver_role: action["approver_role"],
            reason: action["reason"],
            ttl: ttl
          }
        end

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

        if action["allow"] || action.empty?
          return allow_decision(ttl: ttl)
        end

        allow_decision(ttl: ttl)
      end

      def allow_decision(ttl: 3600)
        { action: "allow", ttl: ttl }
      end

      # Matching functions
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
        field_meta       = @registry.dig(request[:dataset], "fields") || {}
      
        # Extracting per-field attributes
        categories = requested_fields
          .map { |f| field_meta[f]&.dig("category") }
          .compact
          .map(&:to_s)
      
        sensitivities = requested_fields
          .map { |f| field_meta[f]&.dig("sensitivity") }
          .compact
          .map(&:to_s)
      
        if rule["category"] && !categories.include?(rule["category"].to_s)
          return false
        end
      
        if rule["sensitivity"] && !sensitivities.include?(rule["sensitivity"].to_s)
          return false
        end
      
        if rule["contains"]
          needed = Array(rule["contains"]).map(&:to_s)
          return false if (needed - categories).any?
        end
      
        if rule["any"] && (requested_fields & rule["any"]).empty?
          return false
        end
      
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

require "yaml"
require_relative "matchers/time_window"
require_relative "ttl_parser"

module Vkit
  module Core
    class PolicyEngine
      # Priority of outcomes (higher wins)
      PRIORITY = {
        "deny" => 3,
        "require_approval" => 2,
        "mask" => 1,
        "allow" => 0
      }.freeze

      def initialize(policy_dir:, registry:)
        @policies = load_policies(policy_dir)   # array of YAML hashes
        @registry = registry                   # datasets registry from vkit dataset scan
      end

      # Evaluate a parsed AQL request → return a final decision hash
      #
      # Request shape (simplified, you will feed real Funl output):
      # {
      #   dataset: "customers",
      #   fields: ["email", "total_spend"],
      #   requester_role: "analyst",
      #   requester_clearance: "low",
      #   requester_region: "US",
      #   dataset_region: "EU",
      #   time: Time.now,
      #   environment: "production"
      # }
      #
      def evaluate(request)
        decisions = @policies.map { |policy| evaluate_policy(policy, request) }
        final = decisions.max_by { |d| PRIORITY[d[:action]] }
        final || { action: "allow" }
      end

      private

      def load_policies(dir)
        Dir.glob(File.join(dir, "*.yaml")).map { |f| YAML.load_file(f) }
      end

      def evaluate_policy(policy, request)
        return allow unless matches?(policy, request)

        action = policy.fetch("action", {})
        ttl = Vkit::Core::TTLParser.parse(action["ttl"]) rescue nil

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
            ttl: ttl || 3600
          }
        end

        allow
      end

      def allow
        {
          action: "allow",
          ttl: 3600
        }
      end

      # ---------------- MATCHING LOGIC ---------------- #

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
        match = policy.dig("match", "fields")
        return true unless match

        requested_fields = request[:fields]
        dataset_meta = @registry[request[:dataset]] || {}
        field_tags = dataset_meta["fields"] || {}

        sensitivities = requested_fields.map { |f| field_tags[f] }.compact

        # match.fields.sensitivity: "pii"
        if match["sensitivity"] && !sensitivities.include?(match["sensitivity"])
          return false
        end

        # match.fields.contains: [pii, financial]
        if match["contains"] && !(match["contains"] - sensitivities).empty?
          return false
        end

        # match.fields.any: ["email", "name"]
        if match["any"] && (requested_fields & match["any"]).empty?
          return false
        end

        # match.fields.all: ["email", "name"]
        if match["all"] && !(match["all"] - requested_fields).empty?
          return false
        end

        true
      end

      def match_context(policy, request)
        ctx = policy["context"] || {}
        return true if ctx.empty?

        return false if ctx["requester_role"] && ctx["requester_role"] != request[:requester_role]
        return false if ctx["requester_clearance"] && ctx["requester_clearance"] != request[:requester_clearance]
        return false if ctx["requester_region"] && ctx["requester_region"] != request[:requester_region]
        return false if ctx["dataset_region"] && ctx["dataset_region"] != request[:dataset_region]
        return false if ctx["environment"] && ctx["environment"] != request[:environment]

        if time_rule = ctx["time"]
          return false unless Matchers::TimeWindow.matches?(time_rule, request[:time] || Time.now)
        end

        true
      end
    end
  end
end

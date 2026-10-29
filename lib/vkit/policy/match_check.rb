# frozen_string_literal: true

require "set"

module Vkit
  module Policy
    # Finds policies that can never match, by checking them against the
    # registry being bundled and against what the control plane evaluates:
    # a key the engine ignores, a tag or sensitivity no field can have, a
    # dataset that isn't in the registry, or a context value VaultKit never
    # sets. Requester clearance and region are set by admins on users and
    # agent tokens (vaultkit-inc/vaultkit#76), so they're checked like any
    # other value.
    class MatchCheck
      # Labels the scanner's classifier assigns. Always valid, so a pack can
      # cover secrets before a database has any.
      CLASSIFIER_TAGS = %w[pii financial credential internal].freeze
      SENSITIVITIES = %w[high medium low].freeze

      MATCH_KEYS = %w[dataset fields context].freeze
      FIELD_KEYS = %w[any all contains sensitivity].freeze
      CONTEXT_KEYS = %w[environment dataset_region requester_role requester_region requester_clearance time].freeze
      ENVIRONMENTS = %w[production staging development sandbox].freeze
      REGIONS = %w[EU US CA APAC].freeze
      CLEARANCES = %w[low medium high].freeze

      Result = Struct.new(:errors, keyword_init: true)

      def self.call(policies, registry)
        new(registry).call(policies)
      end

      def initialize(registry)
        fields = Array(registry["datasets"]).flat_map { |ds| Array(ds["fields"]) }
        @datasets = Array(registry["datasets"]).map { |ds| ds["name"].to_s }.to_set
        @tags = (CLASSIFIER_TAGS + fields.flat_map { |f| Array(f["tags"]).map(&:to_s) }).to_set
        @sensitivities = (SENSITIVITIES + fields.map { |f| f["sensitivity"].to_s }).reject(&:empty?).to_set
      end

      def call(policies)
        errors = []
        policies.each do |policy|
          where = "#{policy['__file'] || policy['id']} (#{policy['id']})"
          problems(policy).each { |p| errors << "#{where}: #{p}" }
        end
        Result.new(errors: errors)
      end

      private

      def problems(policy)
        match = policy["match"] || {}
        return ["match must be a mapping"] unless match.is_a?(Hash)

        unknown_keys(match.keys, MATCH_KEYS, "match") +
          dataset_problems(match["dataset"]) +
          field_problems(match["fields"]) +
          context_problems(policy["context"], "context") +
          context_problems(match["context"], "match.context") +
          mask_problems(policy, match)
      end

      def unknown_keys(keys, allowed, path)
        (keys.map(&:to_s) - allowed).map do |key|
          next "#{path}.category isn't supported: the engine ignores it. Use `contains: [<category>]` instead." if key == "category"

          "#{path}.#{key} isn't supported, so the engine ignores it. Allowed: #{allowed.join(', ')}"
        end
      end

      def dataset_problems(dataset)
        return [] if dataset.nil? || @datasets.include?(dataset.to_s)

        ["dataset #{dataset} isn't in datasets/registry.yaml. Scan the datasource, or fix the name."]
      end

      def field_problems(fields)
        return [] if fields.nil?
        return ["match.fields must be a mapping"] unless fields.is_a?(Hash)

        problems = unknown_keys(fields.keys, FIELD_KEYS, "match.fields")
        tags = Array(fields["contains"]).map(&:to_s)
        unknown = tags.reject { |t| @tags.include?(t) }
        problems << "no field has the tag #{unknown.join(', ')}. Known tags: #{@tags.to_a.sort.join(', ')}" if unknown.any?
        if fields.key?("sensitivity") && !@sensitivities.include?(fields["sensitivity"].to_s)
          problems << "sensitivity #{fields['sensitivity']} never occurs. Use one of: #{@sensitivities.to_a.join(', ')}"
        end
        problems
      end

      def context_problems(context, path)
        return [] if context.nil?
        return ["#{path} must be a mapping"] unless context.is_a?(Hash)

        unknown_keys(context.keys, CONTEXT_KEYS, path) + context.filter_map do |key, value|
          case key.to_s
          when "requester_clearance"
            "#{path}.requester_clearance #{value} isn't one of: #{CLEARANCES.join(', ')}" unless CLEARANCES.include?(value.to_s)
          when "requester_region"
            "#{path}.requester_region #{value} isn't one of: #{REGIONS.join(', ')}" unless REGIONS.include?(value.to_s)
          when "time"
            "#{path}.time only works under match.context." if path == "context"
          when "environment"
            "#{path}.environment #{value} isn't one of: #{ENVIRONMENTS.join(', ')}" unless ENVIRONMENTS.include?(value.to_s)
          when "dataset_region"
            "#{path}.dataset_region #{value} isn't one of: #{REGIONS.join(', ')}" unless REGIONS.include?(value.to_s)
          end
        end
      end

      def mask_problems(policy, match)
        return [] unless policy.dig("action", "mask") == true
        return [] if match["fields"].is_a?(Hash) && (match["fields"].keys.map(&:to_s) & %w[any contains sensitivity]).any?

        ["a mask policy needs match.fields (any, contains or sensitivity) to say which fields to mask"]
      end
    end
  end
end

# frozen_string_literal: true

module Vkit
  module Policy
    class PolicyValidator
      ACTION_KEYS = %w[deny require_approval mask allow].freeze

      def self.validate!(policy, file: nil)
        prefix = file ? "In #{file}:\n\n" : ""

        require_string!(policy, "id", prefix)
        require_string!(policy, "description", prefix)

        action = policy["action"]
        unless action.is_a?(Hash)
          raise ValidationError, <<~MSG
            #{prefix}Invalid action format.

            Expected:

              action:
                deny: true

            Got:

              action: #{action.inspect}

            VaultKit requires `action` to be a mapping so it can attach
            metadata like reason, ttl, approvals, and masking rules.
          MSG
        end

        validate_action!(action, policy, prefix)
        true
      end

      def self.require_string!(hash, key, prefix)
        value = hash[key]
        return if value.is_a?(String) && !value.strip.empty?

        raise ValidationError, <<~MSG
          #{prefix}#{key} is required and must be a non-empty string.
        MSG
      end

      def self.validate_action!(action, policy, prefix)
        intents = ACTION_KEYS.select { |k| action[k] == true }

        if intents.empty?
          raise ValidationError, <<~MSG
            #{prefix}Action must specify exactly one intent.

            Choose one of:

              - deny
              - require_approval
              - mask
              - allow

            Example:

              action:
                deny: true
          MSG
        end

        if intents.size > 1
          raise ValidationError, <<~MSG
            #{prefix}Action specifies multiple intents: #{intents.join(', ')}.

            Only one intent may be set to true.
          MSG
        end

        intent = intents.first

        case intent
        when "deny"
          require_reason!(action, prefix)

        when "require_approval"
          require_reason!(action, prefix)
          require_string!(action, "approver_role", prefix)

        when "mask"
          # masking is optional, but if present must be valid
          validate_masking!(policy, prefix) if policy.key?("masking")

        when "allow"
          # nothing required
        end

        validate_ttl!(action["ttl"], prefix) if action.key?("ttl")
      end

      def self.require_reason!(action, prefix)
        reason = action["reason"]
        return if reason.is_a?(String) && !reason.strip.empty?

        raise ValidationError, <<~MSG
          #{prefix}action.reason is required and must be a non-empty string
          when using deny or require_approval.
        MSG
      end

      def self.validate_ttl!(ttl, prefix)
        case ttl
        when Integer
          return
        when String
          return if ttl.match?(/\A\d+[smhd]\z/)

          raise ValidationError, <<~MSG
            #{prefix}Invalid ttl format.

            Expected examples:
              - "30m"
              - "1h"
              - "2d"

            Got:
              ttl: #{ttl.inspect}
          MSG
        else
          raise ValidationError, <<~MSG
            #{prefix}ttl must be a string duration (e.g. "1h") or an integer (seconds).
          MSG
        end
      end

      # Masking validation (aligned with compiler + runtime)
      def self.validate_masking!(policy, prefix)
        masking = policy["masking"]
        return unless masking

        unless masking.is_a?(Hash)
          raise ValidationError, "#{prefix}masking must be a mapping."
        end

        allowed_keys = %w[default_method rules]
        unknown_keys = masking.keys - allowed_keys

        if unknown_keys.any?
          raise ValidationError, <<~MSG
            #{prefix}Unknown keys in masking: #{unknown_keys.join(', ')}

            Allowed keys:
              - default_method
              - rules
          MSG
        end

        if masking["default_method"]
          validate_mask_method!(
            masking["default_method"],
            prefix,
            "masking.default_method"
          )
        end

        if masking["rules"]
          unless masking["rules"].is_a?(Hash)
            raise ValidationError,
              "#{prefix}masking.rules must be a mapping of field → method."
          end

          masking["rules"].each do |field, method|
            validate_mask_method!(
              method,
              prefix,
              "masking.rules.#{field}"
            )
          end
        end
      end

      def self.validate_mask_method!(method, prefix, path)
        allowed = %w[redact hash truncate nullify full partial]

        unless allowed.include?(method.to_s)
          raise ValidationError, <<~MSG
            #{prefix}Invalid masking method at #{path}.

            Allowed values:
              - redact
              - hash
              - truncate
              - nullify
              - full
              - partial

            Got:
              #{method.inspect}
          MSG
        end
      end
    end
  end
end

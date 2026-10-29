require "json"
require "yaml"
require "digest"
require "time"
require_relative "policy_validator"
require_relative "match_check"
require_relative "tenancy_check"
require_relative "validation_error"

module Vkit
  module Policy
    class BundleCompiler
      FORMAT_VERSION = "v1"

      # Raises if a policy can never match (see MatchCheck).
      def self.compile!(org_slug:, bundle_version:, policies_dir:, registry_dir:, source: {})
        policies = load_policies(policies_dir)
        raw_registry = load_raw_registry(registry_dir)
        registry = normalize_registry(raw_registry)
        check_matches!(policies, registry, raw_registry)

        bundle = {
          "bundle" => {
            "format_version" => FORMAT_VERSION,
            "org_slug" => org_slug,
            "bundle_version" => bundle_version,
            "created_at" => Time.now.utc.iso8601,
            "source" => normalize_source(source),
            "checksum" => "" # filled below
          },
          "registry" => registry,
          "policies" => normalize_policies(policies),
          "signing" => nil
        }

        bundle["bundle"]["installed_packs"] = load_installed_packs
        canonical = canonical_json(bundle)
        bundle["bundle"]["checksum"] = Digest::SHA256.hexdigest(canonical)

        bundle
      end

      # Loading
      def self.load_policies(dir)
        files = Dir[File.join(dir, "*.y{a,}ml")].sort
        raise "No policy files found in #{dir}" if files.empty?

        files.map do |f|
          data = YAML.load_file(f)
          raise "Policy file #{f} must be a Hash" unless data.is_a?(Hash)

          PolicyValidator.validate!(data, file: File.basename(f))

          data.merge("__file" => File.basename(f))
        end
      end

      def self.check_matches!(policies, registry, raw_registry)
        errors = MatchCheck.call(policies, registry).errors + TenancyCheck.call(raw_registry)
        return if errors.empty?

        raise ValidationError, <<~MSG
          These policies or datasets would never protect anything as written:

          #{errors.map { |e| "  - #{e}" }.join("\n")}

          Fix or remove them. If they came from a policy pack, `vkit policy pack upgrade` installs
          versions that can match.
        MSG
      end

      def self.load_raw_registry(dir)
        path = File.join(dir, "registry.yaml")
        raise "Missing datasets/registry.yaml" unless File.exist?(path)

        YAML.load_file(path) || {}
      end

      # Normalization
      # Unknown values (a repo with no origin remote) are left out: the
      # bundle schema requires strings where they are present.
      def self.normalize_source(source)
        { "type" => "git" }.merge(source.transform_keys(&:to_s).compact)
      end

      def self.normalize_policies(policies)
        seen = {}

        normalized = policies.map do |p|
          id = p["id"].to_s.strip
          raise "Policy id missing in #{p["__file"]}" if id.empty?
          raise "Duplicate policy id: #{id}" if seen[id]
          seen[id] = true

          {
            "id" => id,
            "description" => p["description"],
            "match" => p["match"],
            "when" => p["context"],          # ADAPT authoring → runtime
            "action" => normalize_action(p["action"]),
            "reason" => p.dig("action", "reason"),
            "approval" => extract_approval(p),
            "masking" => extract_masking(p),
            "ttl_seconds" => p.dig("action", "ttl"),
            "priority" => p["priority"]
          }.compact
        end

        normalized.sort_by { |p| [-(p["priority"] || 0), p["id"]] }
      end

      def self.normalize_action(action)
        return "allow" unless action.is_a?(Hash)

        return "deny" if action["deny"]
        return "require_approval" if action["require_approval"]
        return "mask" if action["mask"]
        "allow"
      end

      def self.extract_approval(p)
        return unless p.dig("action", "require_approval")
        { "approver_role" => p.dig("action", "approver_role") }
      end

      def self.extract_masking(p)
        return unless p.dig("action", "mask")
      
        raw =
          p["masking"] ||
          p.dig("action", "masking") || {}
      
        default_method =
          normalize_mask_method(raw["default_method"]) if raw["default_method"]
      
        rules =
          case raw["rules"]
          when Hash
            raw["rules"].each_with_object({}) do |(field, method), acc|
              acc[field.to_s] = normalize_mask_method(method)
            end
          else
            {}
          end
      
        result = {}
        result["default_method"] = default_method if default_method
        result["rules"] = rules if rules.any?
      
        return if result.empty?
      
        result
      end

      def self.normalize_registry(raw)
        datasets = raw.map do |name, data|
          {
            "name" => name.to_s,
            "datasource" => data["datasource"].to_s,
            # A field name confines every query to the requester's tenant;
            # false (a deliberately shared table) only matters to TenancyCheck.
            "tenant_column" => (data["tenant_column"] if data["tenant_column"].is_a?(String)),
            "fields" => normalize_fields(data["fields"] || {})
          }.compact
        end
      
        datasources =
          datasets
            .map { |d| d["datasource"] }
            .uniq
            .map { |ds| { "name" => ds, "type" => "postgres", "config" => {} } }
      
        {
          "datasets" => datasets,
          "datasources" => datasources
        }
      end      

      def self.normalize_fields(fields)
        fields.map do |name, meta|
          {
            "name" => name.to_s,
            "type" => meta["type"],
            "sensitivity" => meta["sensitivity"].to_s,
            "tags" => [meta["category"]].compact.map(&:to_s)
          }
        end
      end

      # The control plane's methods (full, partial, hash) pass through; the
      # older names map onto them. Anything else masks fully.
      def self.normalize_mask_method(method)
        case method.to_s
        when "full", "partial", "hash" then method.to_s
        when "truncate" then "partial"
        else "full"
        end
      end

      # Canonicalization
      def self.canonical_json(obj)
        JSON.generate(sort_keys_deep(obj))
      end

      def self.sort_keys_deep(value)
        case value
        when Hash
          value.keys.sort.each_with_object({}) { |k, h| h[k] = sort_keys_deep(value[k]) }
        when Array
          value.map { |v| sort_keys_deep(v) }
        else
          value
        end
      end

      def self.load_installed_packs
        tracking_path = File.join(".vkit", "packs.yaml")
        return [] unless File.exist?(tracking_path)
      
        data = YAML.safe_load(File.read(tracking_path), permitted_classes: [], permitted_symbols: [], aliases: true)
        packs = data["installed_packs"] || {}
      
        packs.map do |name, meta|
          {
            "name" => name,
            "version" => meta["version"]
          }
        end
      rescue
        []
      end      
    end
  end
end

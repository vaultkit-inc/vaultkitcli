require "json"
require "yaml"
require "digest"
require "time"

module Vkit
  module Policy
    class BundleCompiler
      FORMAT_VERSION = "v1"

      def self.compile!(org_slug:, bundle_version:, policies_dir:, registry_dir:, source: {})
        policies = load_policies(policies_dir)
        registry = load_registry(registry_dir)

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
          data.merge("__file" => File.basename(f))
        end
      end

      def self.load_registry(dir)
        path = File.join(dir, "registry.yaml")
        raise "Missing datasets/registry.yaml" unless File.exist?(path)

        raw = YAML.load_file(path)
        normalize_registry(raw)
      end

      # Normalization
      def self.normalize_source(source)
        { "type" => "git" }.merge(source.transform_keys(&:to_s))
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
        p["masking"]
      end

      def self.normalize_registry(raw)
        datasets = raw.map do |name, data|
          {
            "name" => name.to_s,
            "datasource" => data["datasource"].to_s,
            "fields" => normalize_fields(data["fields"] || {})
          }
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
    end
  end
end

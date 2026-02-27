# frozen_string_literal: true

module Vkit
  module Core
    class RegistryDiff
      def self.compute(local:, remote:)
        local ||= {}
        remote ||= {}

        local_datasets  = normalize(local)
        remote_datasets = normalize(remote)

        out = { "datasets" => [] }

        all_names = (local_datasets.keys | remote_datasets.keys).sort

        all_names.each do |name|
          local_fields  = local_datasets[name] || []
          remote_fields = remote_datasets[name] || []

          changes = diff_fields(local_fields, remote_fields)

          next if changes.values.all?(&:empty?)

          out["datasets"] << {
            "name" => name,
            "changes" => changes
          }
        end

        out
      end

      def self.normalize(registry)
        return {} unless registry.is_a?(Hash)
      
        # CASE 1: runtime export format
        if registry.key?("datasets")
          return Array(registry["datasets"]).each_with_object({}) do |ds, h|
            h[ds["name"]] =
              Array(ds["fields"]).map do |f|
                {
                  "name" => f["name"].to_s,
                  "type" => f["type"].to_s,
                  "sensitivity" => f["sensitivity"].to_s,
                  "tags" => Array(f["tags"]).map(&:to_s).sort
                }
              end.sort_by { |f| f["name"] }
          end
        end
      
        # CASE 2: local YAML format
        registry.each_with_object({}) do |(dataset_name, ds), h|
          fields = ds["fields"] || {}
      
          normalized_fields =
            fields.map do |field_name, meta|
              {
                "name" => field_name.to_s,
                "type" => meta["type"].to_s,
                "sensitivity" => meta["sensitivity"].to_s,
                "tags" => [meta["category"]].compact.map(&:to_s).sort
              }
            end.sort_by { |f| f["name"] }
      
          h[dataset_name.to_s] = normalized_fields
        end
      end
      

      def self.diff_fields(local, remote)
        l = local.each_with_object({}) { |f, h| h[f["name"]] = f }
        r = remote.each_with_object({}) { |f, h| h[f["name"]] = f }

        {
          "added_fields" =>
            (r.keys - l.keys).map { |k| r[k] },

          "removed_fields" =>
            (l.keys - r.keys).map { |k| l[k] },

          "changed_fields" =>
            (l.keys & r.keys).filter_map do |k|
              next if l[k] == r[k]
              { "name" => k, "local" => l[k], "remote" => r[k] }
            end
        }
      end

      private_class_method :diff_fields, :normalize
    end
  end
end

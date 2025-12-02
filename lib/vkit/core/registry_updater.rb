# lib/vkit/core/registry_updater.rb
require "yaml"

module Vkit
  module Core
    class RegistryUpdater
      REGISTRY_PATH = "datasets/registry.yaml"

      def update(classified_schema, datasource_id:)
        # Load YAML OR fallback to empty Hash properly
        registry =
          if File.exist?(REGISTRY_PATH)
            loaded = YAML.load_file(REGISTRY_PATH)
            loaded.is_a?(Hash) ? loaded : {}
          else
            {}
          end

        # Build normalized structure
        classified_schema.each do |entry|
          table_name = entry[:table] || entry["table"]
          columns    = entry[:columns] || entry["columns"]

          registry[table_name] ||= {}
          registry[table_name]["datasource"] = datasource_id
          registry[table_name]["fields"] = {}

          columns.each do |column|
            registry[table_name]["fields"][column[:name]] = {
              "type"           => column[:type],
              "classification" => column[:classification],
              "sensitivity"    => column[:sensitivity],
              "category"       => column[:category]
            }
          end
        end

        File.write(REGISTRY_PATH, registry.to_yaml)
        registry
      end
    end
  end
end

require "yaml"

module Vkit
  module Core
    class RegistryUpdater
      REGISTRY_PATH = "datasets/registry.yaml"

      def update(classified_schema)
        registry = File.exist?(REGISTRY_PATH) ? YAML.load_file(REGISTRY_PATH) : {}

        classified_schema.each do |table|
          registry[table[:table]] ||= {}
          registry[table[:table]]["classified_fields"] = table[:columns]
        end

        File.write(REGISTRY_PATH, registry.to_yaml)
        registry
      end
    end
  end
end

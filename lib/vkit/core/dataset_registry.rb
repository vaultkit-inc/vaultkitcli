require "yaml"

module Vkit
  module Core
    class DatasetRegistry
      DEFAULT_PATH = "datasets/registry.yaml"

      def self.load(dataset_name, path: DEFAULT_PATH)
        yaml = YAML.load_file(path)
        entry = yaml[dataset_name]
        raise "Unknown dataset: #{dataset_name}" unless entry

        entry.transform_keys(&:to_sym)
      end
    end
  end
end

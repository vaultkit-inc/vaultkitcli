require_relative "../../core/dataset_scanner"
require_relative "../../core/classifier"
require_relative "../../core/registry_updater"

module Vkit
  module CLI
    module Commands
      class ScanCommand
        def call(datasource_id)
          scanner = Vkit::Core::DatasetScanner.new(datasource_id: datasource_id)
          raw_schema = scanner.scan

          classifier = Vkit::Core::Classifier.new
          classified = classifier.classify(raw_schema)

          updater = Vkit::Core::RegistryUpdater.new
          updated_registry = updater.update(classified)

          puts "✅ Scan complete. Updated registry.yaml:"
          puts YAML.dump(updated_registry)
        rescue => e
          puts "❌ Scan failed: #{e.message}"
          exit 1
        end
      end
    end
  end
end

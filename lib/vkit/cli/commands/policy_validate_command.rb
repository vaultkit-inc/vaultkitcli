require "json"
require_relative "../policy_bundle_validator"
require_relative "../../policy/pack_integrity"

module Vkit
  module CLI
    module Commands
      class PolicyValidateCommand
        def call(bundle_path:, schema_path:)
          bundle_path = File.expand_path(bundle_path)
          raise "Bundle not found: #{bundle_path}" unless File.exist?(bundle_path)
        
          schema_path ||= default_schema_path
          raise "Schema not found: #{schema_path}" unless File.exist?(schema_path)
        
          validator = Vkit::CLI::PolicyBundleValidator.new(
            schema_path: schema_path
          )
        
          validator.validate!(bundle_path)
          Vkit::Policy::PackIntegrity.check_bundle!(JSON.parse(File.read(bundle_path)))
        
          puts "✅ Policy bundle is valid"
        rescue Vkit::Policy::ValidationError => e
          puts e.message
          exit 1
        end        

        private

        def default_schema_path
          File.expand_path("../../policy/schema/policy_bundle.schema.json", __dir__)
        end
      end
    end
  end
end

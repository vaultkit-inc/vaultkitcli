require_relative "../policy_bundle_validator"

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
        
          puts "✅ Policy bundle is valid"
        end        

        private

        def default_schema_path
          File.expand_path("../../policy/schema/policy_bundle.schema.json", __dir__)
        end
      end
    end
  end
end

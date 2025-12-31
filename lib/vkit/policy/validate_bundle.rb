require "json"
require "json_schemer"

module Vkit
  module Policy
    class ValidateBundle
      def self.call!(bundle_path:, schema_path:)
        bundle_path = File.expand_path(bundle_path)
        schema_path = File.expand_path(schema_path)

        raise "Bundle not found: #{bundle_path}" unless File.exist?(bundle_path)
        raise "Schema not found: #{schema_path}" unless File.exist?(schema_path)

        bundle = JSON.parse(File.read(bundle_path))
        schema = JSON.parse(File.read(schema_path))

        schemer = JSONSchemer.schema(schema)
        errors = schemer.validate(bundle).to_a

        if errors.any?
          raise ValidationError.new(errors)
        end

        true
      end

      class ValidationError < StandardError
        attr_reader :errors

        def initialize(errors)
          @errors = errors
          super("Bundle schema validation failed")
        end
      end
    end
  end
end

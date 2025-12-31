require "json"
require "json_schemer"

module Vkit
  module CLI
    class PolicyBundleValidator
      def initialize(schema_path:)
        @schema = JSON.parse(File.read(schema_path))
        @schemer = JSONSchemer.schema(@schema)
      end

      def validate!(bundle_path)
        bundle = JSON.parse(File.read(bundle_path))
        errors = @schemer.validate(bundle).to_a

        return if errors.empty?

        puts "\n❌ Policy bundle validation failed\n\n"

        errors.each do |err|
          puts format_error(err, bundle)
        end

        puts "\nFix the errors above and re-run validation."
        exit 1
      end

      private

      def format_error(err, bundle)
        pointer = err["data_pointer"]
        policy = policy_from_pointer(pointer, bundle)

        msg = []
        msg << "Policy: #{policy || 'global'}"
        msg << "Path: #{human_path(pointer)}"
        msg << "Error: #{human_message(err)}"

        msg.join("\n  ")
      end

      def policy_from_pointer(pointer, bundle)
        return nil unless pointer =~ %r{/policies/(\d+)}

        index = Regexp.last_match(1).to_i
        bundle.dig("policies", index, "id")
      end

      def human_path(pointer)
        pointer
          .gsub("/", ".")
          .sub(".", "")
          .gsub(/\.(\d+)/, '[\1]')
      end

      def human_message(err)
        case err["error"]
        when /missing required properties/
          missing = err.dig("details", "missing_keys")&.join(", ")
          "Missing required field(s): #{missing}"
        when /disallowed additional property/
          "This field is not allowed in the compiled policy bundle"
        when /type/
          "Invalid value type"
        else
          err["error"]
        end
      end
    end
  end
end

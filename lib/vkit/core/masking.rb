module Vkit
  module Core
    module Masking
      # Given dataset + fields + registry:
      # Returns an array of fields that should be masked.
      def self.mask_fields(dataset:, requested_fields:, registry:)
        dataset_meta = registry[dataset] || {}
        field_tags = dataset_meta["fields"] || {}

        requested_fields.select do |field|
          field_tags[field] == "pii"  # mask only PII for now
        end
      end
    end
  end
end

module Vkit
  module Core
    module Masking

      # Args:
      #   dataset: "customers"
      #   requested_fields: ["email", "total_spend"]
      #   registry: {"customers" => { "fields" => {"email"=>"pii","total_spend"=>"financial"} } }
      #   decision: {
      #     mask_fields:   ["email"],
      #     mask_category: ["pii"],
      #     mask_except:   ["id"]
      #   }
      #
      # Returns: array of fields to mask

      def self.resolve_masks(dataset:, requested_fields:, registry:, decision:)
        meta = registry[dataset] || {}
        field_meta = meta["fields"] || {}

        mask_fields   = decision[:mask_fields]
        mask_category = decision[:mask_category]
        mask_except   = decision[:mask_except]

        # mask_fields: explicit list
        if mask_fields
          return requested_fields & mask_fields
        end

        # mask_except: mask ALL except
        if mask_except
          return requested_fields - mask_except
        end

        # mask_category: mask by sensitivity type
        if mask_category
          return requested_fields.select do |field|
            mask_category.include?(field_meta[field])
          end
        end

        # Default masking: PII only
        requested_fields.select do |field|
          field_meta[field] == "pii"
        end
      end

    end
  end
end

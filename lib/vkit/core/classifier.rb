module Vkit
  module Core
    class Classifier
      #  SIGNALS → keyword matches
      #  These detect what kind of column this is
      SIGNAL_KEYWORDS = {
        email:       %w[email email_address],
        phone:       %w[phone phone_number mobile],
        address:     %w[address street city state postal zipcode zip],
        name:        %w[first_name last_name full_name name],
        dob:         %w[birth dob birthdate birthday],
        ssn:         %w[ssn social security],
        credit_card: %w[credit card pan cvv expiry],
        ip:          %w[ip ip_address ipv4 ipv6],
        country:     %w[country nation locale],
        amount:      %w[amount total spend price balance revenue income cost]
      }

      #  SIGNAL → CATEGORY mapping
      CATEGORY_MAP = {
        email:       :pii,
        phone:       :pii,
        address:     :pii,
        name:        :pii,
        dob:         :pii,
        ssn:         :pii,
        credit_card: :pii,
        ip:          :pii,

        amount:      :financial,
        country:     :internal,

        generic:     :internal
      }

      #  CATEGORY → SENSITIVITY mapping
      SENSITIVITY_MAP = {
        pii:        :medium,
        financial:  :medium,
        internal:   :low
      }

      #  MAIN ENTRY
      def classify(raw_schema)
        raw_schema.map do |table_name, columns|
          {
            table: table_name,
            columns: columns.map { classify_column(_1) }
          }
        end
      end

      private

      def classify_column(column)
        name = column[:name].downcase

        # Determine signal match
        signal = SIGNAL_KEYWORDS.find { |signal, words|
          words.any? { |w| name.include?(w) }
        }&.first || :generic

        # Determine category
        category = CATEGORY_MAP[signal] || :internal

        # Determine sensitivity
        sensitivity = SENSITIVITY_MAP[category] || :low

        {
          name: column[:name],
          type: column[:type],
          classification: signal,
          category: category,
          sensitivity: sensitivity
        }
      end
    end
  end
end

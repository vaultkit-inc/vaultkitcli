# lib/vkit/core/classifier.rb

module Vkit
  module Core
    class Classifier
      KEYWORDS = {
        email:       %w[email email_address],
        phone:       %w[phone phone_number mobile],
        address:     %w[address street city state postal zipcode zip],
        name:        %w[first_name last_name full_name],
        dob:         %w[birth dob birthdate birthday],
        ssn:         %w[ssn social security],
        credit_card: %w[credit card pan cvv expiry],
        user_id:     %w[user_id uid],
        ip:          %w[ip ip_address ipv4 ipv6]
      }

      def classify(table_schema)
        table_schema.map do |table, columns|
          {
            table: table,
            columns: columns.map { classify_column(_1) }
          }
        end
      end

      private

      def classify_column(column)
        name = column[:name].downcase

        label = KEYWORDS.find { |_, words|
          words.any? { |w| name.include?(w) }
        }&.first

        {
          name: column[:name],
          type: column[:type],
          classification: label || :generic
        }
      end
    end
  end
end

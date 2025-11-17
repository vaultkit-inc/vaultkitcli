module Vkit
  module Core
    module TTLParser
      def self.parse(raw)
        return nil unless raw
        case raw
        when String
          if raw =~ /^(\d+)h$/i
            $1.to_i * 3600
          elsif raw =~ /^(\d+)m$/i
            $1.to_i * 60
          elsif raw =~ /^(\d+)s$/i
            $1.to_i
          else
            raise "Invalid TTL format: #{raw}. Use examples: 30m, 2h, 90s"
          end
        when Integer
          raw
        else
          raise "Invalid TTL type: #{raw.class}"
        end
      end
    end
  end
end

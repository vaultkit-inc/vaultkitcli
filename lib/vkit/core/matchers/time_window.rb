module Vkit
  module Core
    module Matchers
      class TimeWindow
        def self.matches?(rule, now = Time.now)
          after = parse_minutes(rule["after"])
          before = parse_minutes(rule["before"])
          current = now.hour * 60 + now.min

          if after < before
            # Normal range (09:00 to 18:00)
            current >= after && current <= before
          else
            # Wrap range (18:00 to 09:00)
            current >= after || current <= before
          end
        end

        def self.parse_minutes(str)
          h, m = str.split(":").map(&:to_i)
          (h * 60) + m
        end
      end
    end
  end
end

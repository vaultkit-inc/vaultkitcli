module Vkit
  module Core
    class TableFormatter
      def self.render(rows)
        return puts "(no rows)" if rows.nil? || rows.empty?

        headers = rows.first.keys

        # Calculate column widths
        col_widths = headers.map do |h|
          [h.length, *rows.map { |r| r[h].to_s.length }].max
        end

        # Builders
        def self.border(col_widths)
          "+" + col_widths.map { |w| "-" * (w + 2) }.join("+") + "+"
        end

        def self.row(values, col_widths)
          "|" + values.map.with_index { |v, i| " #{v.to_s.ljust(col_widths[i])} " }.join("|") + "|"
        end

        # Print table
        puts border(col_widths)
        puts row(headers, col_widths)
        puts border(col_widths)

        rows.each do |row|
          puts row(row.values_at(*headers), col_widths)
        end

        puts border(col_widths)
      end
    end
  end
end

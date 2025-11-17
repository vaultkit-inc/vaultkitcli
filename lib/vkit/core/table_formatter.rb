module Vkit
  module Core
    class TableFormatter
      def self.render(rows)
        return puts "(no rows)" if rows.nil? || rows.empty?

        headers = rows.first.keys
        col_widths = headers.map { |h| [h.length, *rows.map { |r| r[h].to_s.length }].max }

        # header row
        line = headers.map.with_index { |h, i| h.ljust(col_widths[i]) }.join(" | ")
        puts line
        puts "-" * line.length

        # data rows
        rows.each do |row|
          puts headers.map.with_index { |h, i| row[h].to_s.ljust(col_widths[i]) }.join(" | ")
        end
      end
    end
  end
end

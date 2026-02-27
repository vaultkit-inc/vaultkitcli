# frozen_string_literal: true

require_relative "ansi"

module Vkit
  module Core
    class RegistryDiffPrinter
      def self.print(diff)
        datasets = diff["datasets"] || []

        summary = summarize(datasets)

        if summary[:total_changes].zero?
          puts Ansi.green("✓ No differences between local registry and runtime.")
          return
        end

        print_summary(summary)
        puts

        datasets.each do |ds|
          changes = ds["changes"]
          next if changes.values.all?(&:empty?)

          puts Ansi.blue("Dataset: #{ds['name']}")
          puts

          print_added(changes["added_fields"])
          print_removed(changes["removed_fields"])
          print_changed(changes["changed_fields"])

          puts "-" * 50
        end
      end

      def self.summarize(datasets)
        datasets.each_with_object(
          datasets_changed: 0,
          added: 0,
          removed: 0,
          changed: 0,
          total_changes: 0
        ) do |ds, acc|
          changes = ds["changes"] || {}

          a = Array(changes["added_fields"]).size
          r = Array(changes["removed_fields"]).size
          c = Array(changes["changed_fields"]).size

          next if a + r + c == 0

          acc[:datasets_changed] += 1
          acc[:added] += a
          acc[:removed] += r
          acc[:changed] += c
          acc[:total_changes] += (a + r + c)
        end
      end

      def self.print_summary(summary)
        line = [
          "#{summary[:datasets_changed]} datasets changed",
          "#{summary[:added]} added",
          "#{summary[:removed]} removed",
          "#{summary[:changed]} modified"
        ].join(" | ")

        puts Ansi.yellow(line)
      end

      def self.print_added(fields)
        return if fields.empty?

        puts Ansi.green("  + Added Fields:")
        fields.each do |f|
          puts Ansi.green("    + #{f['name']} (#{f['type']})")
        end
        puts
      end

      def self.print_removed(fields)
        return if fields.empty?

        puts Ansi.red("  - Removed Fields:")
        fields.each do |f|
          puts Ansi.red("    - #{f['name']} (#{f['type']})")
        end
        puts
      end

      def self.print_changed(fields)
        return if fields.empty?

        puts Ansi.yellow("  ~ Changed Fields:")
        fields.each do |f|
          puts Ansi.yellow("    ~ #{f['name']}")
          puts Ansi.gray("        From: #{f['from']}")
          puts Ansi.gray("        To:   #{f['to']}")
        end
        puts
      end

      private_class_method :summarize,
                           :print_summary,
                           :print_added,
                           :print_removed,
                           :print_changed
    end
  end
end

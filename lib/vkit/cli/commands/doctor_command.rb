# frozen_string_literal: true

require_relative "../doctor"
require_relative "../../core/credential_store"

module Vkit
  module CLI
    module Commands
      # vkit doctor: runs Doctor's checks and reports them. Exits 0 only when
      # none failed; under --format json a failure is status "error"
      # (doctor_checks_failed) with the checks still in result.
      class DoctorCommand < BaseCommand
        ICONS = { "pass" => "✓", "warn" => "!", "fail" => "✗", "info" => "i" }.freeze

        def initialize(runner: nil)
          super()
          @runner = runner
        end

        def call(dir: ".")
          runner = @runner || Vkit::CLI::Doctor::Runner.new(store: credential_store, project_root: File.expand_path(dir))
          runner.run
          report = runner.to_h
          print_report(report)

          if runner.failed?
            failed = report["checks"].select { |c| c["status"] == "fail" }
            message = "#{failed.size} of #{report['checks'].size} checks failed: " \
                      "#{failed.map { |c| Vkit::CLI::Doctor::LABELS[c['name']] }.join(', ')}."
            raise Vkit::CLI::CommandError.new(message, code: "doctor_checks_failed",
                                                       fix: [failed.map { |c| c["fix"] }.compact.uniq.join(" ")],
                                                       result: report) if json?

            exit 1
          end

          respond(report)
        end

        private

        def requires_auth?
          false
        end

        def print_report(report)
          width = Vkit::CLI::Doctor::LABELS.values.map(&:length).max
          puts "vkit doctor"
          puts
          order = Vkit::CLI::Doctor::LABELS.keys
          (report["checks"] + report["skipped"]).sort_by { |c| order.index(c["name"]) || order.size }.each do |c|
            label = Vkit::CLI::Doctor::LABELS.fetch(c["name"], c["name"]).ljust(width)
            if c.key?("status")
              puts "  #{ICONS[c['status']]} #{label}  #{c['detail']}"
              puts "    #{' ' * width}  #{c['status'] == 'info' ? '' : 'Fix: '}#{c['fix']}" if c["fix"] && c["status"] != "pass"
            else
              puts "  - #{label}  Skipped: #{c['reason']}"
              puts "    #{' ' * width}  #{c['fix']}" if c["fix"]
            end
          end
          counts = report["summary"]
          puts
          puts "  #{counts['pass']} passed, #{counts['warn']} #{counts['warn'] == 1 ? 'warning' : 'warnings'}, " \
               "#{counts['fail']} failed#{", #{counts['info']} info" if counts['info'].to_i.positive?}#{", #{report['skipped'].size} skipped" if report['skipped'].any?}"
        end
      end
    end
  end
end

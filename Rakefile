# frozen_string_literal: true

require "rake/testtask"

# Every Ruby file under test/ (except shared helpers in test/support) must be a
# *_test.rb file, so none is silently left out of the run.
task :check_test_files do
  stray = Dir["test/**/*.rb"].reject { |f| f.start_with?("test/support/") || f.end_with?("_test.rb") }
  abort "Test files the runner would skip (rename to *_test.rb or move to test/support):\n  #{stray.join("\n  ")}" if stray.any?
end

# Each file is required in turn, so one that fails to load stops the run
# with an error instead of being skipped.
Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.pattern = "test/**/*_test.rb"
  t.warning = false
end

task test: :check_test_files
task default: :test

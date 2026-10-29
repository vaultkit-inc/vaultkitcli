# frozen_string_literal: true

# Run with: ruby -Ilib test/scan_command_test.rb
require "minitest/autorun"
require_relative "../lib/vkit/cli/commands/base_command"
require_relative "../lib/vkit/cli/commands/scan_command"

class ScanCommandDiffTest < Minitest::Test
  def print_diff(response)
    out, = capture_io do
      Vkit::CLI::Commands::ScanCommand.new.send(:print_diff, response)
    end
    out
  end

  def no_changes
    { "added_fields" => [], "removed_fields" => [], "changed_fields" => [] }
  end

  def suggestion
    {
      "name" => "key_value",
      "current" => { "sensitivity" => "low", "tags" => ["internal"] },
      "suggested" => { "sensitivity" => "high", "tags" => ["credential"] }
    }
  end

  def test_prints_suggestions_after_the_changes_of_a_changed_dataset
    out = print_diff({
      "diff" => {
        "datasets" => [
          {
            "name" => "settings",
            "changes" => no_changes.merge("added_fields" => [{ "name" => "api_token", "type" => "text" }]),
            "suggestions" => [suggestion]
          }
        ]
      }
    })

    added_at     = out.index("+ api_token (text)")
    suggested_at = out.index("? key_value  low/internal → high/credential (suggested)")

    assert added_at, out
    assert suggested_at, out
    assert_operator added_at, :<, suggested_at
    assert_includes out, "1 changed · run with --mode apply"
    assert_includes out, "datasets/registry.yaml and redeploy the bundle."
  end

  def test_responses_without_suggestions_still_work
    out = print_diff({
      "diff" => {
        "datasets" => [
          { "name" => "orders", "changes" => no_changes.merge("removed_fields" => ["legacy_id"]) },
          { "name" => "customers", "changes" => no_changes }
        ]
      }
    })

    assert_includes out, "- legacy_id"
    assert_includes out, "customers"
    assert_includes out, "1 changed · run with --mode apply"
    refute_includes out, "?"
    refute_includes out, "registry.yaml"
  end

  def test_clean_dataset_with_suggestions_still_lists_them
    out = print_diff({
      "diff" => {
        "datasets" => [
          { "name" => "settings", "changes" => no_changes, "suggestions" => [suggestion] }
        ]
      }
    })

    assert_match(/settings\s+✓/, out)
    assert_includes out, "? key_value  low/internal → high/credential (suggested)"
    assert_includes out, "No changes detected"
    assert_includes out, "datasets/registry.yaml and redeploy the bundle."
  end

  def test_untagged_labels_show_only_the_sensitivity
    out = print_diff({
      "diff" => {
        "datasets" => [
          {
            "name" => "settings",
            "changes" => no_changes,
            "suggestions" => [suggestion.merge("current" => { "sensitivity" => "low", "tags" => [] })]
          }
        ]
      }
    })

    assert_includes out, "? key_value  low → high/credential (suggested)"
  end
end

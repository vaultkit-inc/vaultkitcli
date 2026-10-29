# frozen_string_literal: true

# Run with: ruby -Ilib test/bundle_compiler_test.rb
require "minitest/autorun"
require_relative "../lib/vkit/policy/bundle_compiler"

class BundleCompilerTest < Minitest::Test
  Compiler = Vkit::Policy::BundleCompiler

  def masking_for(method)
    Compiler.extract_masking(
      "action" => { "mask" => true },
      "masking" => { "default_method" => method, "rules" => { "email" => method } }
    )
  end

  def test_control_plane_methods_pass_through
    %w[full partial hash].each do |method|
      assert_equal({ "default_method" => method, "rules" => { "email" => method } }, masking_for(method))
    end
  end

  def test_older_method_names_map_onto_control_plane_methods
    assert_equal "partial", masking_for("truncate")["default_method"]
    assert_equal "full", masking_for("redact")["default_method"]
    assert_equal "full", masking_for("nullify")["default_method"]
  end

  def test_source_leaves_out_unknown_values
    source = Compiler.normalize_source(repo: nil, ref: "main", commit_sha: "abc1234")

    assert_equal({ "type" => "git", "ref" => "main", "commit_sha" => "abc1234" }, source)
  end
end

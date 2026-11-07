# frozen_string_literal: true

require "yaml"

# The versions and policy counts of the packs this CLI ships, so tests follow
# the packs instead of hard-coding them and breaking on every pack release.
module ShippedPacks
  ROOT = File.expand_path("../../lib/vkit/policy/packs", __dir__)

  module_function

  def version(pack)
    YAML.safe_load(File.read(File.join(ROOT, pack, "metadata.yaml"))).dig("__pack_meta", "version")
  end

  def policy_count(pack)
    Dir[File.join(ROOT, pack, "policies", "*.yaml")].size
  end

  def total(packs)
    packs.sum { |pack| policy_count(pack) }
  end
end

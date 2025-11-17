require "yaml"
require_relative "../lib/vkit/core/policy_engine"

# Load registry
registry = YAML.load_file("datasets/registry.yaml")

# Initialize Policy Engine
engine = Vkit::Core::PolicyEngine.new(
  policy_dir: "config/policies",
  registry: registry
)

# Simulated request
request = {
  dataset: "customers",
  fields: ["email", "total_spend"],   # contains both pii + financial
  requester_role: "analyst",
  requester_region: "US",
  dataset_region: "EU",
  time: Time.now,
  environment: "production"
}

decision = engine.evaluate(request)
if decision[:action] == "require_approval"
  store = Vkit::Core::ApprovalStore.new
  req_id = store.enqueue(
    request,
    reason: decision[:reason],
    approver_role: decision[:approver_role]
  )

  puts "⏳ Request queued for approval: #{req_id}"
  puts "Required Approver Role: #{decision[:approver_role]}"
  exit 0
end

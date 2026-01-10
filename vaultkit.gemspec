# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = "vaultkit"
  spec.version       = "0.1.2"
  spec.authors       = ["Nnamdi Ogundu"]
  spec.email         = ["founders@vaultkit.io"]

  spec.summary       = "VaultKit CLI"
  spec.description   = "Command-line interface for interacting with the VaultKit control plane"
  spec.homepage      = "https://vaultkit.io"
  spec.license       = "Nonstandard"

  spec.required_ruby_version = ">= 3.0"
  spec.require_paths = ["lib"]

  spec.files = Dir[
    "lib/**/*",
    "bin/*",
    "README.md"
  ]

  spec.executables = ["vkit"]
  spec.bindir = "bin"

  spec.add_dependency "thor", "~> 1.2"

  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = "https://github.com/ndbaba1/vaultkitcli"
end

require_relative "lib/agentd/version"

Gem::Specification.new do |s|
  s.name        = "agentd"
  s.version     = Agentd::VERSION
  s.summary     = "Ruby client and CLI for agentd.link — agent identity, messaging, tasks, memory, and payments"
  s.description = "Provision and interact with AI agents on agentd.link via a simple Ruby API or CLI."
  s.authors     = ["agentd.link"]
  s.homepage    = "https://agentd.link"
  s.license     = "MIT"
  s.files       = Dir["lib/**/*.rb"]
  s.require_paths = ["lib"]
  s.required_ruby_version = ">= 3.0"

  s.add_dependency "faraday",       ">= 2.0"
  s.add_dependency "faraday-retry", ">= 2.0"
  s.add_dependency "thor",          ">= 1.2"

  s.executables = ["agentd"]
  s.bindir      = "bin"
end

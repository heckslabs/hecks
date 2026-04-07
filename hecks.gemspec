require_relative "lib/hecks/version"

Gem::Specification.new do |spec|
  spec.name          = "hecks"
  spec.version       = Hecks::VERSION
  spec.authors       = ["Christopher Young"]
  spec.summary       = "Hexagonal DDD framework for Ruby"
  spec.description   = "Domain compiler: DSL, IR, runtime, generators, CLI, workshop, and AI tools"
  spec.homepage      = "https://github.com/chrisyoung/hecks"
  spec.license       = "MIT"

  spec.files         = Dir["lib/**/*.rb"] + ["README.md", "FEATURES.md", "hecks_logo.png"]
  spec.require_paths = ["lib"]
  spec.bindir        = "bin"
  spec.executables   = ["hecks"]

  spec.required_ruby_version = ">= 3.0"

  spec.add_dependency "rwordnet", ">= 1.0", "< 3.0"
  spec.add_dependency "sequel", ">= 5.0"
end

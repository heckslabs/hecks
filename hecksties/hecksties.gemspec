require_relative "lib/hecks/version"

Gem::Specification.new do |spec|
  spec.name          = "hecksties"
  spec.version       = Hecks::VERSION
  spec.authors       = ["Christopher Young"]
  spec.license       = "MIT"
  spec.homepage      = "https://github.com/chrisyoung/hecks"
  spec.summary       = "Core kernel of the Hecks hexagonal DDD framework"
  spec.description   = "Core kernel of the Hecks hexagonal DDD framework"

  spec.required_ruby_version = ">= 3.0"
  spec.require_paths = ["lib"]
  spec.files         = Dir["lib/**/*"] + ["README.md"]

  spec.add_dependency "bluebook", Hecks::VERSION
  spec.add_dependency "rwordnet", ">= 1.0", "< 3.0"
  spec.add_dependency "activemodel", ">= 6.0", "< 10.0"
end

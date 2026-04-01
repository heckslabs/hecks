require_relative "../hecksties/lib/hecks/version"

Gem::Specification.new do |s|
  s.name        = "bluebook"
  s.version     = Hecks::VERSION
  s.summary     = "Domain command language, model types, DSL builders, and code generators for Hecks"
  s.description = "The BlueBook — grammar, IR nodes, validators, compiler, and visualizer for domain modeling"
  s.authors     = ["Chris Young"]
  s.license     = "MIT"
  s.homepage    = "https://github.com/chrisyoung/hecks"
  s.files       = Dir["lib/**/*.rb"]
  s.require_paths = ["lib"]
  s.required_ruby_version = ">= 3.0"
end

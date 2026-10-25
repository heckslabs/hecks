require_relative "../../lib/hecks/version"

Gem::Specification.new do |spec|
  spec.name        = "hecks-rails"
  spec.version     = Hecks::VERSION
  spec.authors     = ["Chris Young"]
  spec.summary     = "Rails as a driving adapter over a Hecks domain: models, routes, controllers and forms without ActiveRecord."
  spec.description = <<~DESC
    A Rails app keeps its models, routes, controllers, form helpers and `errors`, and every rule
    lives in the bluebook. Rails authenticates and renders; the domain decides.
  DESC
  spec.homepage = "https://github.com/heckslabs/hecks"
  spec.license  = "Apache-2.0"

  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "app/views/**/*.erb", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "actionpack", ">= 7.1"
  spec.add_dependency "activemodel", ">= 7.1"
  spec.add_dependency "hecks", "= #{Hecks::VERSION}"
  spec.add_dependency "railties", ">= 7.1"
end

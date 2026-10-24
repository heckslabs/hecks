# The Rails driving adapter ships at the version of the hecks it was built against.
require_relative "../../lib/hecks/version"

Gem::Specification.new do |spec|
  spec.name        = "hecks-rails"
  spec.version     = Hecks::VERSION
  spec.authors     = ["Chris Young"]
  spec.summary     = "Drive a Hecks domain from Rails: thin models, derived routes, named controller actions."
  spec.description = <<~DESC
    A Rails app keeps its domain in bluebook/ and reaches it through thin models, routes
    drawn from the domain's verbs, and controllers with one named action per verb. Rules stay
    in the bluebook; nothing here authors one.
  DESC
  spec.homepage = "https://github.com/heckslabs/hecks"
  spec.license  = "Apache-2.0"

  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir.chdir(__dir__) { Dir.glob(["lib/**/*.rb", "config/*.yml", "README.md"]) }
  spec.require_paths = ["lib"]

  spec.add_dependency "activemodel", ">= 7.1"
  spec.add_dependency "hecks", Hecks::VERSION
  spec.add_dependency "railties", ">= 7.1"
  spec.metadata["rubygems_mfa_required"] = "true"
end

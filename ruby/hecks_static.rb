# = HecksStatic
#
# Standalone domain generator for Hecks. Loaded from the Targets::Ruby
# Bluebook chapter — the chapter lists every aggregate, and
# load_aggregates derives the require tree from naming conventions.
#
# == Usage
#
#   require "hecks_static"
#   domain = Hecks.domain("Pizzas") { ... }
#   HecksStatic::GemGenerator.new(domain).generate
#
#   # Or via CLI:
#   hecks build --standalone
#
Hecks::Chapters.load_aggregates(
  Hecks::Targets::Ruby,
  base_dir: File.expand_path("hecks_static", __dir__)
)

# Self-register static Ruby target when loaded
Hecks.register_target(:static) do |domain, version: "0.1.0", output_dir: ".", smoke_test: true, **|
  valid, errors = Hecks.validate(domain)
  raise Hecks::ValidationError.for_domain(errors) unless valid

  root = HecksStatic::GemGenerator.new(domain, version: version, output_dir: output_dir).generate
  Hecks.send(:run_ruby_smoke_test, root, domain) if smoke_test
  root
end

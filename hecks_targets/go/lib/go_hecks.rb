# = GoHecks
#
# Go domain generator for Hecks. Loaded from the Targets::Go
# Bluebook chapter — the chapter lists every aggregate, and
# load_aggregates derives the require tree from naming conventions.
#
# == Usage
#
#   require "go_hecks"
#   domain = Hecks.domain("Pizzas") { ... }
#   GoHecks::ProjectGenerator.new(domain).generate
#
#   # Or via CLI:
#   hecks build --target go
#
Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Targets::Go,
  base_dir: File.expand_path("go_hecks", __dir__)
)

# Self-register Go targets when loaded
Hecks.register_target(:go) do |domain, output_dir: ".", smoke_test: true, **|
  generator = GoHecks::ProjectGenerator.new(domain, output_dir: output_dir)
  root = generator.generate
  if smoke_test
    Hecks.send(:run_smoke_test, root, domain) rescue nil
  end
  root
end

Hecks.register_target(:binary) do |domain, output_dir: "bin", **|
  GoHecks::BinaryBuilder.build(domain, output_dir: output_dir)
end

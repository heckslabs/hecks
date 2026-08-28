# lib/hecks/version.rb, NOT "lib/hecks" — the whole
# framework, not just VERSION, the moment this required more; see that
# file's own header for the real chicken-and-egg bug this avoids.
require_relative "lib/hecks/version"

Gem::Specification.new do |spec|
  spec.name        = "hecks"
  spec.version     = Hecks::VERSION
  spec.authors     = ["Chris Young"]
  spec.summary     = "A domain is data: aggregates, commands, and invariants declared in .bluebook, run directly by this runtime."
  spec.description = <<~DESC
    hecks reads a .bluebook file — a business domain's aggregates,
    value objects, commands, and invariants — and boots it directly.
    Nothing is scripted: no handler body, no class you write, no schema
    you migrate.
  DESC
  spec.homepage = "https://github.com/heckslabs/hecks"
  spec.license  = "Apache-2.0"

  spec.required_ruby_version = ">= 3.2"

  # Dir.glob, not `git ls-files` — this has to build the same way inside a
  # Bundler git checkout as it does in a plain working copy, and the former
  # is not guaranteed to carry a usable .git directory.
  spec.files = Dir.chdir(__dir__) { Dir.glob("lib/**/*", File::FNM_DOTMATCH).select { |f| File.file?(f) } }
  spec.require_paths = ["lib"]

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"]   = spec.homepage

  # UNLIKE Postgres/Sqlite (ADAPTERS, reached only if a domain's
  # .hecksagon wires one — declaring them here would force a database
  # client library on every project that never touches either), prism
  # is a genuinely unconditional dependency: adapters/driven/prism.rb's
  # own `require "prism"` runs the moment `require "hecks"` does,
  # not lazily. Real, not merely tidy — Ruby 3.3+ bundles prism as a
  # default gem so this went unnoticed everywhere prism was already
  # present for free; Ruby 3.2 (AWS Lambda's own managed runtime, among
  # others) does not, and `require "hecks"` failed outright there
  # with prism undeclared (caught live building for Lambda).
  spec.add_dependency "prism"
end

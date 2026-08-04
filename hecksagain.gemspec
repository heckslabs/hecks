require_relative "lib/hecksagain"

Gem::Specification.new do |spec|
  spec.name        = "hecksagain"
  spec.version     = Hecksagain::VERSION
  spec.authors     = ["Chris Young"]
  spec.summary     = "A domain is data: aggregates, commands, and invariants declared in .bluebook, run directly by this runtime."
  spec.description = <<~DESC
    hecksagain reads a .bluebook file — a business domain's aggregates,
    value objects, commands, and invariants — and boots it directly.
    Nothing is scripted: no handler body, no class you write, no schema
    you migrate. Not published to rubygems.org; installed as a git or
    path dependency by projects that build on it, the way this
    gemspec exists to let Bundler do.
  DESC
  spec.homepage = "https://github.com/chrisyoung/hecksagain"
  spec.license  = "Apache-2.0"

  spec.required_ruby_version = ">= 3.2"

  # Dir.glob, not `git ls-files` — this has to build the same way inside a
  # Bundler git checkout as it does in a plain working copy, and the former
  # is not guaranteed to carry a usable .git directory.
  spec.files = Dir.chdir(__dir__) { Dir.glob("lib/**/*", File::FNM_DOTMATCH).select { |f| File.file?(f) } }
  spec.require_paths = ["lib"]

  spec.metadata["allowed_push_host"] = "https://this.gem.is.not.published"

  # Postgres/Sqlite are ADAPTERS, reached only if a domain's .hecksagon
  # wires one — the runtime itself boots on the in-memory adapter with
  # neither installed. Declaring them here would force a database client
  # library on every project that never touches either.
end

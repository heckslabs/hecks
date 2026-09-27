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
  #
  # The dev tooling stays in the repository (ADR 0066): these read or
  # rewrite `examples/`, `qa/`, `spec/`, `rust/` or `docs/`, which an
  # install does not carry, and nothing `lib/hecks.rb` loads requires them.
  # spec/gemspec_packaging_spec.rb holds both halves of that.
  dev_tooling = %r{\Alib/hecks/(fuzzing/|fuzzing\.rb\z|bench/|bench\.rb\z|corpus\.rb\z|codemod\.rb\z|
                   query_ir\.rb\z|grammar/evolve\.rb\z|doc/)}x
  spec.files = Dir.chdir(__dir__) do
    (Dir.glob("lib/**/*", File::FNM_DOTMATCH) + ["exe/hecks"])
      .select { |f| File.file?(f) }
      .grep_v(dev_tooling)
  end
  spec.bindir      = "exe"
  spec.executables = ["hecks"]
  spec.require_paths = ["lib"]

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"]   = spec.homepage
  spec.metadata["changelog_uri"]     = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "https://rubydoc.info/gems/hecks"

  # Unlike Postgres/Sqlite (adapters, loaded only if a domain's .hecksagon
  # wires one), prism is a genuinely unconditional dependency:
  # adapters/driven/prism.rb requires it the moment `require "hecks"` runs,
  # not lazily. Ruby 3.3+ bundles prism as a default gem, but Ruby 3.2
  # (AWS Lambda's managed runtime, among others) does not, so it must be
  # declared here explicitly.
  spec.add_dependency "prism"
end

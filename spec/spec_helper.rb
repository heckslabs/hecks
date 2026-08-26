$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    enable_coverage :branch
    add_filter "/spec/"
  end
end

require "hecks"

module InMemoryDomain
  ROOT             = File.expand_path("..", __dir__)
  PIZZAS_BLUEBOOK  = File.join(ROOT, "examples/pizzas/bluebook/pizzas.bluebook")
  BANKING_BLUEBOOK_DIR = File.join(ROOT, "examples/banking/bluebook").freeze
  PERSISTENCE_PORT = File.join(ROOT, "lib/hecks/ports/persistence.port")
  EXTRACTION_PORT  = File.join(ROOT, "lib/hecks/ports/extraction.port")
  MEMORY_ADAPTER   = File.join(ROOT, "lib/hecks/adapters/driven/memory.adapter")
  PRISM_ADAPTER    = File.join(ROOT, "lib/hecks/adapters/driven/prism.adapter")
  POSTGRES_ADAPTER = File.join(ROOT, "lib/hecks/adapters/driven/postgres.adapter")
  POSTGRES_ERA_ADAPTER = File.join(ROOT, "lib/hecks/adapters/driven/postgres_era.adapter")
  # ADR 0033 — the era/lineage plugin is not core-required; a spec that binds
  # PostgresEra must `require "hecks/ports/persistence/plugins/era"` itself,
  # same as any other consumer would.
  ERA_PLUGIN = "hecks/ports/persistence/plugins/era"

  # A chapter may reopen across several business-concept files. Load the set
  # inside the same deferred validation window Runtime::Loader uses, then judge
  # the completed chapter once rather than treating each file as a domain.
  def load_bluebook_files(path)
    if path.is_a?(Array)
      Hecks::Bluebook::MetaValidator.defer { path.each { |file| Kernel.load(file) } }
      return Hecks::Bluebook::MetaValidator.judge_deferred!(Hecks.current_registry)
    end

    folder = Hecks::Adapters::Folder.new
    return folder.load_bluebooks(folder.bluebook_directory(path)) unless File.file?(path)

    folder.load_bluebooks(File.dirname(path), [File.basename(path)])
  end
  module_function :load_bluebook_files

  def boot_in_memory
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(PERSISTENCE_PORT)
      Kernel.load(EXTRACTION_PORT)
      Kernel.load(MEMORY_ADAPTER)
      Kernel.load(PRISM_ADAPTER)
      Kernel.load(PIZZAS_BLUEBOOK)

      # `::` on purpose — a real .hecksagon file is loaded at TOP LEVEL, where an
      # unresolved constant reaches Object's const_missing (ConstShim ->
      # BindingProxy). This block lives inside a module, so a bare `Pizzas`
      # would be looked up here first and reach no hook at all.
      Hecks.hecksagon("Pizzas") do
        uses_framework "Governance"
        ::Pizzas::Order.persisted_by("Memory")
      end
      Hecks.hecksagon("Governance") do
        ::Governance::RoleAssignment.persisted_by("Memory")
        ::Governance::RoleTransition.persisted_by("Memory")
      end
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(
      Hecks::Runtime::Dispatcher.new(registry)
    )
  end
end

RSpec.configure do |config|
  config.include InMemoryDomain

  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random

  # `io: true` marks a spec (or single example) that does real,
  # uncontrolled I/O — a subprocess spawn, a live Postgres/D1
  # connection, a `cargo build` — the kind of thing that made a plain
  # local `bundle exec rspec` slow even though most of it self-skips
  # when the resource isn't reachable. CI (.github/workflows/ci.yml)
  # provisions everything for real and always sets `CI`, so it runs
  # these unfiltered; run them locally on demand with
  # `CI=true bundle exec rspec` or `bundle exec rspec --tag io`.
  config.filter_run_excluding io: true unless ENV["CI"]

  # `fuzzing: true` — every example under spec/fuzzing/, tagged by
  # PATH rather than by hand at each file (`define_derived_metadata`,
  # not a per-file `:fuzzing` label to keep in sync). Not `io: true`
  # itself — nothing here does real I/O, it's slow for a different
  # reason: a live-generated-history replay against a real domain,
  # dispatched for real, several seeds deep, run twice over
  # (`properties_spec.rb`'s own "standard battery" + determinism
  # check alone is ~8s of a suite that's otherwise ~50ms/example).
  # Same shape as `io: true` — excluded from the everyday local loop,
  # run automatically on every commit instead (`.githooks/post-commit`,
  # `bundle exec rspec spec/fuzzing --tag fuzzing`), and unfiltered in
  # CI. Run on demand with `bundle exec rspec spec/fuzzing --tag fuzzing`.
  config.define_derived_metadata(file_path: %r{/spec/fuzzing/}) { |metadata| metadata[:fuzzing] = true }
  config.filter_run_excluding fuzzing: true unless ENV["CI"]
end

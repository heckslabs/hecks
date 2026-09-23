$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    enable_coverage :branch
    add_filter "/spec/"
  end
end

require "hecks"
require_relative "support/ci_skip_backstop"

# Shared paths and boot helpers for specs that boot a real, in-memory registry
# rather than loading a fixture domain from disk piecemeal.
module InMemoryDomain
  ROOT             = File.expand_path("..", __dir__)
  PIZZAS_BLUEBOOK  = File.join(ROOT, "examples/pizzas/bluebook/pizzas.bluebook")
  BANKING_BLUEBOOK_DIR = File.join(ROOT, "examples/banking/bluebook").freeze
  PERSISTENCE_PORT = File.join(ROOT, "lib/hecks/ports/persistence.port")
  EXTRACTION_PORT  = File.join(ROOT, "lib/hecks/ports/extraction.port")
  MEMORY_ADAPTER   = File.join(ROOT, "lib/hecks/adapters/driven/memory.adapter")
  LOCAL_STORAGE_ADAPTER = File.join(ROOT, "lib/hecks/adapters/driven/local_storage.adapter")
  PRISM_ADAPTER    = File.join(ROOT, "lib/hecks/adapters/driven/prism.adapter")
  POSTGRES_ADAPTER = File.join(ROOT, "lib/hecks/adapters/driven/postgres.adapter")
  POSTGRES_ERA_ADAPTER = File.join(ROOT, "lib/hecks/adapters/driven/postgres_era.adapter")
  # ADR 0033 — the era/lineage plugin is not core-required; a spec that binds
  # PostgresEra must `require "hecks/ports/persistence/plugins/era"` itself,
  # same as any other consumer would.
  ERA_PLUGIN = "hecks/ports/persistence/plugins/era".freeze

  # Loads one or more bluebook files as a single chapter.
  #
  # A chapter may reopen across several business-concept files. Load the set
  # inside the same deferred validation window Runtime::Loader uses, then judge
  # the completed chapter once rather than treating each file as a domain.
  #
  # @param path [String, Array<String>] a single file, or every file making up one chapter
  # @return [Object] the judged chapter (when `path` is an Array), or the folder adapter's
  #   own load result (when `path` is a single file or directory)
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

  # Sibling ACL hecksagon `uses_framework "Governance"` needs as of 2.0 —
  # attaching a BC without `Hecks.hecksagon "Governance"` refuses boot.
  # Same Memory binds every in-process spec already used.
  GOVERNANCE_MEMORY_HECKSAGON = <<~HECKSAGON.freeze
    Hecks.hecksagon "Governance" do
      Governance::RoleAssignment.persisted_by("Memory")
      Governance::RoleTransition.persisted_by("Memory")
    end
  HECKSAGON

  GOVERNANCE_POSTGRES_ERA_HECKSAGON = <<~HECKSAGON.freeze
    Hecks.hecksagon "Governance" do
      Governance::RoleAssignment.persisted_by("PostgresEra")
      Governance::RoleTransition.persisted_by("PostgresEra")
    end
  HECKSAGON

  # Sibling world PostgresEra needs once the hecksagon above binds it —
  # EraCheck looks up registry.world("Governance"), not QualityControl's.
  # @param database_url [String] the same URL the consuming domain's world uses
  # @return [String] a `Hecks.world "Governance"` file body
  def self.governance_postgres_era_world(database_url)
    <<~RUBY
      Hecks.world "Governance" do
        persisted_by("PostgresEra") { database "#{database_url}" }
      end
    RUBY
  end

  # @param adapter [String] persistence adapter name (default Memory)
  # @return [void]
  def sibling_governance!(adapter: "Memory")
    Hecks.hecksagon("Governance") do
      ::Governance::RoleAssignment.persisted_by(adapter)
      ::Governance::RoleTransition.persisted_by(adapter)
    end
  end
  module_function :sibling_governance!

  # Boots a fresh, real registry with the Pizzas and Governance chapters wired
  # to the Memory adapter — a minimal real domain, not a stub.
  #
  # @return [Hecks::Runtime::Registry] the booted, bound registry
  def boot_in_memory
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(PERSISTENCE_PORT)
      Kernel.load(EXTRACTION_PORT)
      Kernel.load(MEMORY_ADAPTER)
      Kernel.load(PRISM_ADAPTER)
      Kernel.load(PIZZAS_BLUEBOOK)

      # `::` on purpose — a real .hecksagon file is loaded at top level, where an
      # unresolved constant reaches Object's const_missing (ConstShim ->
      # BindingProxy). This block lives inside a module, so a bare `Pizzas`
      # would be looked up here first and reach no hook at all.
      Hecks.hecksagon("Pizzas") do
        uses_framework "Governance"
        ::Pizzas::Order.persisted_by("Memory")
      end
      sibling_governance!
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

  # Enables `--only-failures` (re-run just what was red last time) and
  # `--next-failure` (the tightest red/fix/re-run loop, one example at a
  # time) — RSpec needs a persistence file to remember status across
  # runs for either to work. `tmp/` is already gitignored; this is
  # local, per-checkout state, never meant to be shared or committed.
  config.example_status_persistence_file_path = "tmp/rspec_examples.txt"

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
  # path rather than by hand at each file (`define_derived_metadata`,
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

  # Under CI, an example that ends skipped fails the run unless
  # spec/support/ci_skip_backstop.rb accounts for its reason — see that
  # file. Locally (no CI) skips stay skips.
  CiSkipBackstop.install(config)
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    enable_coverage :branch
    add_filter "/spec/"
  end
end

require "hecks"
require "tmpdir"

# The suite runs with the verdict cache on but never reads or writes the
# user's real one: a stale file there could hide a judging regression, and a
# run should not leave a megabyte behind. Each run gets a private directory.
VERDICT_CACHE_SPEC_DIR = Dir.mktmpdir("hecks-verdict-cache-spec")
at_exit { FileUtils.rm_rf(VERDICT_CACHE_SPEC_DIR) }
Hecks::Bluebook::MetaValidator::VerdictCache.define_singleton_method(:dir) { VERDICT_CACHE_SPEC_DIR }
require_relative "support/ci_skip_backstop"
require_relative "support/hecks_memory_environment"
require_relative "support/repo_tool"

# A push runs the pre-push hook with GIT_DIR and friends exported, and every
# `git` the suite starts inherits them. Specs build scratch repositories and
# commit into them; with those variables set the commits land in the pushing
# repository instead. Start each suite process without them.
Hecks::Vendoring::GitEnvironment.scrub!

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

  # Loads one or more bluebook files as a single chapter, judging the
  # completed chapter once rather than treating each file as a domain.
  #
  # @param path [String, Array<String>] a single file, or every file making up one chapter
  # @return [Object] the judged chapter (when `path` is an Array), or the folder
  #   adapter's own load result (single file or directory)
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

  # Sibling ACL hecksagon `uses_framework "Governance"` needs — attaching a
  # BC without `Hecks.hecksagon "Governance"` refuses boot. Same Memory
  # binds every in-process spec already used.
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

      # `::` on purpose — a real .hecksagon file loads at top level, where an
      # unresolved constant reaches Object's const_missing. This block lives
      # inside a module, so a bare `Pizzas` would resolve here first instead.
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

  # `io: true` marks an example that does real, uncontrolled I/O (subprocess
  # spawn, live Postgres/D1, `cargo build`) so a plain local run stays fast.
  # CI always sets `CI` and runs these unfiltered; locally use
  # `CI=true bundle exec rspec` or `bundle exec rspec --tag io`.
  config.filter_run_excluding io: true unless ENV["CI"]

  # `fuzzing: true` tags every example under spec/fuzzing/ by path
  # (`define_derived_metadata`) rather than by hand per file. Slow for a
  # different reason than `io: true`: a live-generated-history replay run
  # several seeds deep. Excluded locally, run automatically post-commit
  # and unfiltered in CI; run on demand with
  # `bundle exec rspec spec/fuzzing --tag fuzzing`.
  config.define_derived_metadata(file_path: %r{/spec/fuzzing/}) { |metadata| metadata[:fuzzing] = true }
  config.filter_run_excluding fuzzing: true unless ENV["CI"]

  # Under CI, an example that ends skipped fails the run unless
  # spec/support/ci_skip_backstop.rb accounts for its reason — see that
  # file. Locally (no CI) skips stay skips.
  CiSkipBackstop.install(config)
end

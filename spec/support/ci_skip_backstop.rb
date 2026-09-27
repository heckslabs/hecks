# Fails the suite when an example skips in CI without a named destination.
# `spec/ci_skip_backstop_spec.rb` proves every table entry is still live.
module CiSkipBackstop
  Allowed = Struct.new(:pattern, :call_site, :literal, :workflow, :job, :reason, keyword_init: true)
  Bug = Struct.new(:pattern, :call_site, :literal, :jobs, :why, keyword_init: true)

  # Skips that are fine because the named CI job runs the check; empty while no skip has one.
  ALLOWED = [].freeze

  # Skips with no destination, named as bugs; delete an entry once it stops skipping.
  UNROUTED_BUGS = [
    Bug.new(
      pattern:   %r{\Adocuments examples/pizzas' own real era-1→2 migration},
      call_site: "spec/guides_spec.rb",
      literal:   "documents examples/pizzas' own real era-1→2 migration",
      jobs:      %w[rspec_postgres_io],
      why:       "schema-evolution.md reads examples/pizzas' real era-1→2 history out of hecks_pizzas. CI's database " \
                 "is created fresh (`createdb hecks_pizzas`, ci-postgres-io.yml) with no history, so the whole guide — " \
                 "including its sections that need no history — skips in every CI run and runs nowhere. Fix: seed the " \
                 "era-1→2 history in that job, or split the history section from the rest of the guide."
    )
  ].freeze

  module_function

  # `GOLDEN=rewrite` examples skip by design after rewriting, so the backstop steps aside.
  def enabled? = !ENV["CI"].to_s.empty? && ENV["GOLDEN"] != "rewrite"

  def accounted_for?(message)
    (ALLOWED + UNROUTED_BUGS).any? { |entry| entry.pattern.match?(message) }
  end

  def offenders(examples)
    examples.filter_map do |example|
      result = example.execution_result
      next unless result.status == :pending
      # A pending example that ran and failed as its shrink-only table expects (e.g.
      # RUST_FUZZ_PENDING) is a live check, not a skip; only never-run examples lack an exception.
      next if result.pending_exception

      message = result.pending_message.to_s
      next if accounted_for?(message)

      "#{example.location} #{example.full_description}\n    skipped: #{message}"
    end
  end

  # Registers the `after(:suite)` hook that raises listing every offending example.
  def install(config)
    return unless enabled?

    config.after(:suite) do
      found = CiSkipBackstop.offenders(RSpec.world.all_examples)
      next if found.empty?

      raise "CI skip backstop: #{found.size} example(s) skipped in CI with no destination " \
            "(spec/support/ci_skip_backstop.rb):\n  #{found.join("\n  ")}\n" \
            "In CI a skip must become a failure, or name the CI job that runs the check instead (ALLOWED)."
    end
  end
end

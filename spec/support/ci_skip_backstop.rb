# IN CI, A SKIP IS A FAILURE UNLESS IT SAYS WHERE THE CHECK WENT.
#
# A skipped example is a check that silently left the suite. Locally that
# is the everyday deal (no Postgres, no cargo, no feature built). In CI
# every resource is provisioned on purpose, so a skip there means either
# the job is broken (Postgres didn't come up, a build failed) or the check
# lives somewhere else — and "somewhere else" has to be a real place.
#
# So, under `ENV["CI"]`, after the suite runs every example that ended
# pending is held against two tables:
#
#   ALLOWED — pattern => destination. The skip is fine HERE because the
#     named CI job runs that check for real. spec/ci_skip_backstop_spec.rb
#     proves each destination job exists and runs the call site's spec
#     file, and each pattern still matches a live `skip` call site.
#   UNROUTED_BUGS — skips that happen in CI with NO destination: bugs,
#     named as bugs, so they stop failing the build while someone fixes
#     them but can't be mistaken for "legitimate". The same spec proves
#     each is still live, so a fixed one has to be deleted.
#
# Anything else fails the run (an `after(:suite)` error — non-zero exit)
# listing every offending example and its skip reason.
#
# `GOLDEN=rewrite` is a deliberate rewrite mode whose examples skip after
# rewriting; the backstop stays out of its way.
module CiSkipBackstop
  Allowed = Struct.new(:pattern, :call_site, :literal, :workflow, :job, :reason, keyword_init: true)
  Bug = Struct.new(:pattern, :call_site, :literal, :jobs, :why, keyword_init: true)

  # Empty on purpose today: every skip the CI jobs were observed to take
  # (see UNROUTED_BUGS) has no other lane that runs it. An entry here
  # names the job that DOES run the skipped check, e.g. a Cargo-feature
  # skip in one job whose feature another job builds.
  ALLOWED = [].freeze

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

  def enabled? = !ENV["CI"].to_s.empty? && ENV["GOLDEN"] != "rewrite"

  def accounted_for?(message)
    (ALLOWED + UNROUTED_BUGS).any? { |entry| entry.pattern.match?(message) }
  end

  def offenders(examples)
    examples.filter_map do |example|
      result = example.execution_result
      next unless result.status == :pending
      # A `pending` example RAN and failed the way its shrink-only table
      # says it should (e.g. RUST_FUZZ_PENDING, CODEGEN_PENDING_MEMBERS);
      # it turns into a failure the moment it passes. That is a live check,
      # not a skip — only an example that never ran carries no exception.
      next if result.pending_exception

      message = result.pending_message.to_s
      next if accounted_for?(message)

      "#{example.location} #{example.full_description}\n    skipped: #{message}"
    end
  end

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

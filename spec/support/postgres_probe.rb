# Whether a local Postgres answers at all — asked once, lazily, and
# shared by every spec that used to run this identical probe itself
# (postgres_spec.rb, domain_rename_spec.rb, lineage_spec.rb,
# query_agreement_spec.rb, doctest.rb): a real `PG.connect(dbname:
# "postgres").close` round trip is real I/O, and five independent copies
# of it used to run on every `bundle exec rspec`, all asking the exact
# same question. `@available`'s own memoization is what makes "ONCE" true
# — every caller below reaches this same method.
#
# **Lazy on purpose**: `.available?` must be a method, not a constant computed
# at `require` time. Every caller uses this to decide whether to `skip`
# an `io: true` example/group — and metadata blocks aside, RSpec still
# evaluates a `describe`/`context` body (and therefore any top-level
# constant assignment in it) while building the example tree, before the
# `io: true` filter ever gets a say in what runs. A constant here would
# mean a real Postgres connection attempt on every `bundle exec rspec`,
# tag filter or not. A method called only from inside a `before` hook or
# an example body — both deferred until the example actually runs — means
# a default run (`io: true` excluded) never dials out at all.
#
# **In CI, unreachable is a failure, not a skip**. Every caller turns `false`
# into `skip`, and a skipped Postgres spec is a check that silently left
# the suite: a CI job whose Postgres failed to come up used to go green
# having run none of them. CI provisions Postgres for every job that runs
# a spec reaching this probe (the `rspec_postgres_io*`, `rspec_rust_host`,
# `rspec_fuzzing` and `stress_concurrency` jobs); the light `rspec` shard
# runs `--tag ~io` and never reaches it. `rspec_fuzzing` is the example of
# why this matters: it had no Postgres, so its two io fuzzing specs skipped
# there — and every other io job runs `--tag ~fuzzing`, so they ran nowhere. So under `ENV["CI"]` a
# `false` answer raises
# instead — the whole group fails, naming the connection error. Locally
# (no `CI`) it still answers `false` and the spec skips.
#
# `require "pg"` here, explicitly — hecks's own require is lazy now
# (loaded only where Postgres::connect_for actually connects), so this
# probe can't lean on `require "hecks"` to have loaded it as a side
# effect.
module PostgresProbe
  class Unreachable < StandardError
  end

  def self.available?
    probe! unless defined?(@available)
    return @available if @available || !ENV["CI"]

    raise Unreachable,
          "CI is set but no Postgres answers (#{@failure}) — in CI a Postgres spec fails rather than skips. " \
          "Provision Postgres for this job (.github/actions/postgres), or keep this spec out of it " \
          "(it is `io: true`; a job without Postgres runs `--tag ~io`)."
  end

  def self.probe!
    require "pg"
    PG.connect(dbname: "postgres").close
    @available = true
  rescue LoadError, PG::Error => e
    @failure = "#{e.class}: #{e.message.strip}"
    @available = false
  end
  private_class_method :probe!
end

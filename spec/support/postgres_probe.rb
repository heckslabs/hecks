# Whether a local Postgres answers at all — asked ONCE, lazily, and
# shared by every spec that used to run this identical probe itself
# (postgres_spec.rb, domain_rename_spec.rb, lineage_spec.rb,
# query_agreement_spec.rb, doctest.rb): a real `PG.connect(dbname:
# "postgres").close` round trip is real I/O, and five independent copies
# of it used to run on every `bundle exec rspec`, all asking the exact
# same question. `@available`'s own memoization is what makes "ONCE" true
# — every caller below reaches this same method.
#
# LAZY ON PURPOSE: `.available?` must be a method, not a constant computed
# at `require` time. Every caller uses this to decide whether to `skip`
# an `io: true` example/group — and metadata blocks aside, RSpec still
# evaluates a `describe`/`context` body (and therefore any top-level
# constant assignment in it) while BUILDING the example tree, before the
# `io: true` filter ever gets a say in what runs. A constant here would
# mean a real Postgres connection attempt on every `bundle exec rspec`,
# tag filter or not. A method called only from inside a `before` hook or
# an example body — both deferred until the example actually runs — means
# a default run (`io: true` excluded) never dials out at all.
#
# `require "pg"` HERE, explicitly — hecks's own require is lazy now
# (loaded only where Postgres::connect_for actually connects), so this
# probe can't lean on `require "hecks"` to have loaded it as a side
# effect.
module PostgresProbe
  def self.available?
    return @available if defined?(@available)

    @available =
      begin
        require "pg"
        PG.connect(dbname: "postgres").close
        true
      rescue LoadError, PG::Error
        false
      end
  end
end

# Whether a local Postgres answers at all — asked ONCE, here, and shared
# by every spec that used to run this identical probe itself
# (postgres_spec.rb, domain_rename_spec.rb, lineage_spec.rb,
# query_agreement_spec.rb, doctest.rb): a real `PG.connect(dbname:
# "postgres").close` round trip is real I/O, and five independent copies
# of it used to run on every `bundle exec rspec`, all asking the exact
# same question. `require`'s own memoization is what makes "ONCE" true —
# every file below reaches this same constant via `require_relative`,
# never its own `begin/rescue`.
#
# `require "pg"` HERE, explicitly — hecksagain's own require is lazy now
# (loaded only where Postgres::connect_for actually connects), so this
# probe can't lean on `require "hecksagain"` to have loaded it as a side
# effect.
module PostgresProbe
  AVAILABLE =
    begin
      require "pg"
      PG.connect(dbname: "postgres").close
      true
    rescue LoadError, PG::Error
      false
    end
end

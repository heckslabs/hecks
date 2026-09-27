# Whether a local Postgres answers, probed once and shared by every spec that needs one.
#
# `.available?` is a method, not a constant: RSpec evaluates describe bodies while building the
# example tree, so a constant would dial out on every run, `io: true` filter or not.
# Under `ENV["CI"]` an unreachable Postgres raises rather than answering false, so a job whose
# Postgres failed to come up cannot go green by skipping every spec that needs it.
# `pg` is required here because hecks loads it lazily.
module PostgresProbe
  class Unreachable < StandardError
  end

  # Checks whether a local Postgres answers, probing at most once and
  # memoizing the result for every caller.
  #
  # @return [Boolean] true if a local Postgres answered a real `PG.connect`
  # @raise [PostgresProbe::Unreachable] if `ENV["CI"]` is set and no
  #   Postgres answered
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

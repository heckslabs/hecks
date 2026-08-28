require "spec_helper"
# ADR 0033 — schema-evolution.md's own runnable examples bind PostgresEra
# and exercise bin/scaffold_translation; the era persistence plugin isn't
# core-loaded anymore, so doctests need it explicitly, same as any other
# consumer.
require "hecks/ports/persistence/plugins/era"
require_relative "support/doctest"
require_relative "support/doctest_names"

# Every guide's examples RUN — see spec/support/doctest.rb for the fence
# and marker vocabulary. One example per guide, and now a guide with no
# executable blocks FAILS rather than passing trivially (see the
# vacuous-pass guard inside the `it` below) — coverage is still counted
# per document, not per fence, so a guide that runs one example still
# counts the same as one that runs twenty-seven, but zero is no longer
# on the table. A guide whose first line carries the postgres pragma
# skips cleanly when no local Postgres answers.
RSpec.describe "the guides" do
  # The name gate covers the guides and the DSL reference TOGETHER, since
  # both install into the same global namespace — it lives in
  # spec/support/doctest_names.rb and is asserted once, here.
  it "gives every document its own domain names" do
    expect(DoctestNames.collisions).to be_empty, DoctestNames.collisions.join("\n")
  end

  # docs/*.md sits outside the doctest gate ON PURPOSE — see
  # DoctestNames::UNGATED_STATUS_DOCS's own header for why status/
  # planning prose doesn't belong in `guides`. This is what keeps that
  # a decision rather than a glob accident: a new top-level file nobody
  # has sorted yet fails here, by name, instead of silently joining the
  # exempt set.
  it "never grows the ungated top-level docs by accident" do
    unaccounted = DoctestNames.unaccounted_top_level_docs
    expect(unaccounted).to be_empty,
                           "docs/#{unaccounted.join(', docs/')} landed at the top level with no decision recorded — " \
                           "either give it real fences and move it under guides, or add it to " \
                           "DoctestNames::UNGATED_STATUS_DOCS with the same kind of reason its neighbors carry"
  end

  DoctestNames.guides.each do |path|
    # Parsed here, at collection-build time, not inside the `it` — a
    # guide's postgres pragma has to be known BEFORE the example runs,
    # so it can carry as `io: true` and get excluded locally by default
    # the same as every other real-Postgres spec.
    guide = Doctest.parse(path)

    it "#{File.basename(path)} says nothing its examples cannot back", io: guide.postgres do
      # THE VACUOUS-PASS GUARD — this module's own top comment used to
      # read "a guide with no executable blocks passes trivially" as a
      # known, accepted limitation; language-versioning.md sat at zero
      # fences for exactly that reason until this line existed. A `ruby
      # skip` fence still doesn't count (Doctest.parse never adds it to
      # `blocks`), so this refuses the same non-example a reader already
      # can't trust: a guide's assertions above earn a real fence, or
      # the guide fails here rather than passing by having nothing to
      # run at all.
      expect(guide.blocks).not_to be_empty,
                                  "#{File.basename(path)} has no executable ```ruby fence — it currently proves nothing " \
                                  "it claims; give it at least one real example (a ```ruby skip fence is display-only " \
                                  "and does not count)"

      skip "no reachable Postgres — start one to run this guide" if guide.postgres && !Doctest.postgres_available?
      if File.basename(path) == "schema-evolution.md" && !Doctest.pizzas_history_available?
        skip "documents examples/pizzas' own real era-1→2 migration — only present on a machine " \
             "that actually lived through it, not a fresh hecks_pizzas database"
      end

      expect(Doctest.run(path)).to be(true)
    end
  end
end

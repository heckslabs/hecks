require "spec_helper"
# PostgresEra is not core-loaded; schema-evolution.md's examples need it explicitly.
require "hecks/ports/persistence/plugins/era"
require_relative "support/doctest"
require_relative "support/doctest_names"

# Every guide's examples run (fence vocabulary: spec/support/doctest.rb). Coverage is per document;
# a guide whose first line carries the postgres pragma skips when no local Postgres answers.
RSpec.describe "the guides" do
  # Guides and the DSL reference install into one global namespace, so names are gated together.
  it "gives every document its own domain names" do
    expect(DoctestNames.collisions).to be_empty, DoctestNames.collisions.join("\n")
  end

  # docs/*.md is outside the doctest gate on purpose; an unsorted new top-level file fails by name.
  it "never grows the ungated top-level docs by accident" do
    unaccounted = DoctestNames.unaccounted_top_level_docs
    expect(unaccounted).to be_empty,
                           "docs/#{unaccounted.join(", docs/")} landed at the top level with no decision recorded — " \
                           "either give it real fences and move it under guides, or add it to " \
                           "DoctestNames::UNGATED_STATUS_DOCS with the same kind of reason its neighbors carry"
  end

  def no_fence_message(path)
    "#{File.basename(path)} has no executable ```ruby fence — it currently proves nothing " \
      "it claims; give it at least one real example (a ```ruby skip fence is display-only " \
      "and does not count)"
  end

  # Skips the guide when the machine lacks what it needs: Postgres, or the pizzas era history.
  def skip_when_unavailable(guide, path)
    skip "no reachable Postgres — start one to run this guide" if guide.postgres && !Doctest.postgres_available?
    return unless File.basename(path) == "schema-evolution.md" && !Doctest.pizzas_history_available?

    skip "documents examples/pizzas' own real era-1→2 migration — only present on a machine " \
         "that actually lived through it, not a fresh hecks_pizzas database"
  end

  DoctestNames.guides.each do |path|
    # Parsed at collection time so the postgres pragma can set `io: true` before the example runs.
    it "#{File.basename(path)} says nothing its examples cannot back", :aggregate_failures, io: Doctest.parse(path).postgres do
      guide = Doctest.parse(path)
      # Vacuous-pass guard: a guide with no executable fence (`ruby skip` doesn't count) fails
      # instead of passing with nothing to run.
      expect(guide.blocks).not_to be_empty, no_fence_message(path)

      skip_when_unavailable(guide, path)
      expect(Doctest.run(path)).to be(true)
    end
  end
end

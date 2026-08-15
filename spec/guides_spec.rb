
require "spec_helper"
require_relative "support/doctest"
require_relative "support/doctest_names"

# Every guide's examples RUN — see spec/support/doctest.rb for the fence
# and marker vocabulary. One example per guide; a guide with no
# executable blocks passes trivially; a guide whose first line carries
# the postgres pragma skips cleanly when no local Postgres answers.
RSpec.describe "the guides" do
  # The name gate covers the guides and the DSL reference TOGETHER, since
  # both install into the same global namespace — it lives in
  # spec/support/doctest_names.rb and is asserted once, here.
  it "gives every document its own domain names" do
    expect(DoctestNames.collisions).to be_empty, DoctestNames.collisions.join("\n")
  end

  DoctestNames.guides.each do |path|
    # Parsed here, at collection-build time, not inside the `it` — a
    # guide's postgres pragma has to be known BEFORE the example runs,
    # so it can carry as `io: true` and get excluded locally by default
    # the same as every other real-Postgres spec.
    guide = Doctest.parse(path)

    it "#{File.basename(path)} says nothing its examples cannot back", io: guide.postgres do
      skip "no reachable Postgres — start one to run this guide" if guide.postgres && !Doctest.postgres_available?
      if File.basename(path) == "schema-evolution.md" && !Doctest.pizzas_history_available?
        skip "documents examples/pizzas' own real era-1→2 migration — only present on a machine " \
             "that actually lived through it, not a fresh hecks_pizzas database"
      end

      expect(Doctest.run(path)).to be(true)
    end
  end
end

require "spec_helper"
require "hecks/hecks/adapters/stall_watching"

# The `settled_read` reads: a boarded commit origin/main holds settles its subject, and a row naming
# a read the adapter does not know is refused.
RSpec.describe Hecks::Adapters::StallWatching::SettledReads do
  it "refuses a row naming a read it does not know" do
    reads = described_class.new(origin: ->(_sha) { true })

    expect { reads.call({ settled_read: "guess" }, {}) }.to raise_error(ArgumentError, /unknown settled_read "guess"/)
  end

  it "settles a boarded commit only when origin holds it" do
    reads = described_class.new(origin: ->(sha) { sha == "abc" && "is contained in origin/main" })
    kind = { settled_read: "boarded-on-origin" }

    expect([reads.call(kind, { "boarded" => "abc" }), reads.call(kind, { "boarded" => "def" })])
      .to eq(["its boarded commit abc is on origin/main", nil])
  end
end

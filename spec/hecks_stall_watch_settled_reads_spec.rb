require "spec_helper"
require "hecks/hecks/adapters/stall_watching"

# The `settled_read` reads: git's exit status says whether a boarded commit is on origin/main, and a
# row naming a read the adapter does not know is refused.
RSpec.describe Hecks::Adapters::StallWatching::SettledReads do
  it "refuses a row naming a read it does not know" do
    reads = described_class.new(origin: ->(_sha) { true })

    expect { reads.call({ settled_read: "guess" }, {}) }.to raise_error(ArgumentError, /unknown settled_read "guess"/)
  end

  it "reads git's answer: 0 is on origin, 1 is not, anything else unknown" do
    shell = ->(code) { instance_double(Hecks::Adapters::Shell, capture: Struct.new(:exit_code).new(code)) }

    expect([0, 1, 128].map { |code| described_class.on_origin?(shell.call(code), "abc") }).to eq([true, false, nil])
  end
end

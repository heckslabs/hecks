require "spec_helper"
require "hecks/cli/behaviors"
require "tmpdir"

# `hecks run_behaviors <dir>`: a directory with nothing to run is a mistake, not a pass.
RSpec.describe Hecks::CLI::Behaviors do
  it "exits 1, saying so, for a directory that holds no .behaviors file", :aggregate_failures do
    Dir.mktmpdir("no_behaviors") do |dir|
      expect { described_class.call([dir], program: "hecks run_behaviors") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/no \.behaviors files under/).to_stderr
    end
  end
end

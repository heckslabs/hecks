require "spec_helper"
require "json"
require "hecks/tools/shape"
require "hecks/tools/history"
require "hecks/tools/refresh_projections"

# The library bodies of scripts whose `bin/` file only starts them: each `bin/` file runs one of
# these, and so do the Custodian adapters.
RSpec.describe "the script bodies in lib/hecks/cli" do
  let(:root)   { File.expand_path("..", __dir__) }
  let(:pizzas) { File.join(root, "examples/pizzas/bluebook/pizzas.bluebook") }

  describe Hecks::Tools::Shape do
    it "prints a bluebook's storage shape as JSON" do
      expect(JSON.parse(described_class.render(pizzas))).to be_a(Hash)
    end

    it "prints one label line per domain of a directory" do
      expect(described_class.render(File.dirname(pizzas))).to match(/\APizzas [0-9a-f]+\z/)
    end

    it "refuses a missing path and a directory with no bluebook", :aggregate_failures do
      expect { described_class.render("/nonexistent") }.to raise_error(Hecks::Runtime::NotFound, /does not exist/)
      expect { described_class.render(root) }.to raise_error(Hecks::Runtime::NotFound, /no \*\.bluebook files/)
    end

    it "aborts with usage when given no target", :aggregate_failures do
      expect { expect { described_class.call([]) }.to raise_error(SystemExit) }.to output(/usage/).to_stderr
    end
  end

  describe Hecks::Tools::History do
    it "answers no entries for a repository that is not append-only" do
      expect(described_class.entries(Object.new)).to eq([])
    end

    it "aborts with usage when given no domain", :aggregate_failures do
      expect { expect { described_class.call([]) }.to raise_error(SystemExit) }.to output(/usage/).to_stderr
    end
  end

  describe Hecks::Tools::RefreshProjections do
    it "aborts with usage when given no domain", :aggregate_failures do
      expect { expect { described_class.run([]) }.to raise_error(SystemExit) }.to output(/usage/).to_stderr
    end
  end
end

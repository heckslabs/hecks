require "spec_helper"
require "json"
require "hecks/cli/shape"
require "hecks/cli/history"
require "hecks/cli/follow"
require "hecks/cli/deploy_template_diff"
require "hecks/cli/refresh_projections"

# The library bodies of scripts whose `bin/` file only starts them: each `bin/` file runs one of
# these, and so do the Custodian adapters.
RSpec.describe "the script bodies in lib/hecks/cli" do
  let(:root)     { File.expand_path("..", __dir__) }
  let(:pizzas)   { File.join(root, "examples/pizzas/bluebook/pizzas.bluebook") }
  let(:fixtures) { File.join(root, "spec/fixtures/deploy_template_diff") }

  def capture
    out = StringIO.new
    real = $stdout
    $stdout = out
    yield
    out.string
  ensure
    $stdout = real
  end

  describe Hecks::CLI::Shape do
    it "prints a bluebook's storage shape as JSON" do
      expect(JSON.parse(described_class.render(pizzas))).to be_a(Hash)
    end

    it "prints one label line per domain of a directory" do
      expect(described_class.render(File.dirname(pizzas))).to match(/\APizzas [0-9a-f]+\z/)
    end

    it "refuses a missing path and a directory with no bluebook" do
      expect { described_class.render("/nonexistent") }.to raise_error(Hecks::Runtime::NotFound, /does not exist/)
      expect { described_class.render(root) }.to raise_error(Hecks::Runtime::NotFound, /no \*\.bluebook files/)
    end

    it "aborts with usage when given no target" do
      expect { expect { described_class.call([]) }.to raise_error(SystemExit) }.to output(/usage/).to_stderr
    end
  end

  describe Hecks::CLI::History do
    it "answers no entries for a repository that is not append-only" do
      expect(described_class.entries(Object.new)).to eq([])
    end

    it "aborts with usage when given no domain" do
      expect { expect { described_class.call([]) }.to raise_error(SystemExit) }.to output(/usage/).to_stderr
    end
  end

  describe Hecks::CLI::Follow do
    let(:event) { Struct.new(:aggregate).new("Banking::Account") }

    it "matches every event without a filter, and by bare name, case-insensitively or exactly" do
      expect(described_class.matches?(event, nil)).to be true
      expect(described_class.matches?(event, "account")).to be true
      expect(described_class.matches?(event, "Banking::Account")).to be true
      expect(described_class.matches?(event, "Customer")).to be false
    end

    it "reads its options after the domain" do
      argv = %w[--aggregate Order --interval 2 --from-now]

      expect(described_class.parse(argv, "hecks follow")).to eq(interval: 2.0, from_now: true, aggregate: "Order")
    end
  end

  describe Hecks::CLI::DeployTemplateDiff do
    it "answers 0 for the same template, 1 for a difference and 2 for a missing file" do
      base   = File.join(fixtures, "base.yaml")
      edited = File.join(fixtures, "edited.yaml")

      expect(capture { expect(described_class.call([base, base])).to eq(0) }).not_to be_empty
      expect(capture { expect(described_class.call([base, edited])).to eq(1) }).not_to be_empty
      expect { expect(described_class.call([base, "/nonexistent.yaml"])).to eq(2) }.to output(/./).to_stderr
    end

    it "aborts with usage unless given two templates" do
      expect { expect { described_class.call(["one.yaml"]) }.to raise_error(SystemExit) }.to output(/usage/).to_stderr
    end
  end

  describe Hecks::CLI::RefreshProjections do
    it "aborts with usage when given no domain" do
      expect { expect { described_class.run([]) }.to raise_error(SystemExit) }.to output(/usage/).to_stderr
    end
  end
end

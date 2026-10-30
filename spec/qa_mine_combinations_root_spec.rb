require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/quality_control/cli/qa_mine_combinations"

# The miner keeps its runs under a checkout's tmp/, and never writes into an installed gem.
RSpec.describe Hecks::QualityControlCli::QaMineCombinations do
  let(:dir) { Dir.mktmpdir("mine_root") }

  after { FileUtils.rm_rf(dir) }

  def runs_root(root) = described_class.new(root: root).send(:runs_root)

  it "keeps runs under tmp/ of a writable checkout" do
    File.write(File.join(dir, "hecks.gemspec"), "")
    FileUtils.mkdir_p(File.join(dir, "lib"))

    expect(runs_root(dir)).to eq(File.join(dir, "tmp/qa-mined"))
  end

  it "keeps runs under the cache root when the root is an installed gem" do
    FileUtils.mkdir_p(File.join(dir, "lib"))

    expect(runs_root(dir)).to eq(Hecks::CacheDir.path("qa-mined"))
  end

  it "keeps runs under the cache root when the checkout cannot be written" do
    File.write(File.join(dir, "hecks.gemspec"), "")
    FileUtils.mkdir_p(File.join(dir, "lib"))
    allow(File).to receive(:writable?).and_call_original
    allow(File).to receive(:writable?).with(dir).and_return(false)

    expect(runs_root(dir)).to eq(Hecks::CacheDir.path("qa-mined"))
  end
end

require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/tools"
require "hecks/tools/regeneration_run"

# `regen_codegen_domains --check` projects into a scratch crate and always removes it.
RSpec.describe Hecks::Tools::RegenerationRun do
  let(:root) { Dir.mktmpdir("regen_root") }
  let(:scratches) { [] }

  before do
    FileUtils.mkdir_p(File.join(root, "rust/src/generated"))
    File.write(File.join(root, "rust/Cargo.toml"), "[features]\n")
    allow(described_class).to receive(:plan).and_return(["examples/pizzas"])
    allow(described_class).to receive(:scratch_crate).and_wrap_original do |original, *args|
      original.call(*args).tap { |path| scratches << path }
    end
  end

  after do
    FileUtils.rm_rf(root)
    scratches.each { |path| FileUtils.rm_rf(path) }
  end

  it "removes the scratch crate when a domain aborts the run", :aggregate_failures do
    allow(described_class).to receive(:regenerate).and_raise(SystemExit.new(1))

    expect { described_class.main(["--check"], root: root) }.to raise_error(SystemExit)

    expect(scratches.size).to eq(1)
    expect(Dir.exist?(scratches.first)).to be(false)
  end

  it "removes the scratch crate when a domain raises", :aggregate_failures do
    allow(described_class).to receive(:regenerate).and_raise(RuntimeError, "boom")

    expect { described_class.main(["--check"], root: root) }.to raise_error("boom")

    expect(Dir.exist?(scratches.first)).to be(false)
  end

  it "puts HECKS_RUST_DIR back after an aborted check", :aggregate_failures do
    before = ENV.fetch("HECKS_RUST_DIR", nil)
    allow(described_class).to receive(:regenerate).and_raise(SystemExit.new(1))

    expect { described_class.main(["--check"], root: root) }.to raise_error(SystemExit)

    expect(ENV.fetch("HECKS_RUST_DIR", nil)).to eq(before)
  end
end

require "spec_helper"

RSpec.describe RealHomeGuard do
  let(:state) { File.join(RunSandbox.real_home, ".claude") }

  it "refuses a read of the owner's live ledger" do
    expect { File.exist?(File.join(state, "hecks-dev", "tickets.db")) }.to raise_error(described_class::Violation, /real home/)
  end

  it "refuses a listing of the owner's session state" do
    expect { Dir.glob(File.join(state, "jobs", "*")) }.to raise_error(described_class::Violation)
  end

  it "refuses a path that reaches the real state through a symlink" do
    link = File.join(RunSandbox.path("tmp"), "link")
    File.symlink(state, link)
    expect { File.exist?(File.join(link, "hecks-dev")) }.to raise_error(described_class::Violation)
  end

  it "lets a run read what is in its own home" do
    expect(File.exist?(File.join(Dir.home, ".claude", "hecks-dev", "tickets.db"))).to be(false)
  end

  it "lets a run read an unrelated path in the real home" do
    expect { File.exist?(File.join(RunSandbox.real_home, ".zshrc")) }.not_to raise_error
  end
end

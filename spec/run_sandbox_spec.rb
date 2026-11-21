require "spec_helper"

RSpec.describe RunSandbox do
  it "points the run's home and temporary directory into the sandbox" do
    expect([Dir.home, ENV.fetch("TMPDIR")]).to all(satisfy { |dir| described_class.inside?(dir) })
  end

  it "keeps the owner's real home out of the sandbox" do
    expect(described_class.inside?(described_class.real_home)).to be(false)
  end

  it "stops a git started in the sandbox from climbing out of it" do
    expect(ENV.fetch("GIT_CEILING_DIRECTORIES")).to eq(described_class.root)
  end

  it "resolves symlinks when it asks whether a path is inside" do
    link = File.join(Dir.mktmpdir("hecks-outside"), "link")
    File.symlink(described_class.root, link)
    expect(described_class.inside?(File.join(link, "home"))).to be(true)
  end
end

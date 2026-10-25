require "spec_helper"
require "hecks/rust_build/wasm"

# The wasm build's profile: a release build is the one that ships, a dev build compiles faster and
# is for tests that only run the module.
RSpec.describe Hecks::RustBuild::Wasm do
  it "builds release unless told otherwise" do
    expect(described_class.profile).to eq(flags: ["--release"], dir: "release")
  end

  it "builds without --release for the dev profile" do
    expect(described_class.profile("dev")).to eq(flags: [], dir: "debug")
  end

  it "refuses a profile it does not know" do
    expect { described_class.profile("fast") }.to raise_error(Hecks::RustBuild::Failure, /not release or dev/)
  end

  it "gives cargo the flags of the profile" do
    allow(described_class).to receive(:puts)
    allow(Hecks::RustBuild).to receive(:command!)
    described_class.compile("/tmp/scratch", "dev")

    expect(Hecks::RustBuild).to have_received(:command!)
      .with("rustup", "run", "stable", "cargo", "build", "--target", "wasm32-wasip1", hash_including(chdir: "/tmp/scratch"))
  end
end

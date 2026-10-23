require "spec_helper"
require "tmpdir"
require "hecks/rust_build/target_dir"

# Where Cargo writes: the crate's own `target/` in a checkout, one shared per-user cache for a copy
# installed under `Gem.path`, and `CARGO_TARGET_DIR` over both.
RSpec.describe Hecks::RustBuild::TargetDir do
  let(:gems) { File.realpath(Dir.mktmpdir("gem_home")) }
  let(:installed_copy) { File.join(gems, "bundler", "gems", "hecks-0123456789ab") }
  let(:checkout) { File.realpath(Dir.mktmpdir("checkout")) }
  let(:cache) { File.join(checkout, "cache") }

  before { allow(Gem).to receive(:path).and_return([gems]) }

  after { FileUtils.rm_rf([gems, checkout]) }

  def target_for(root, **env)
    Hecks::RustBuild.with_env({ "CARGO_TARGET_DIR" => nil, "XDG_CACHE_HOME" => cache }.merge(env)) do
      described_class.for(File.join(root, "rust", "host"), root: root)
    end
  end

  it "keeps a checkout's build in the crate's own target/" do
    expect(target_for(checkout)).to eq(File.join(checkout, "rust", "host", "target"))
  end

  it "sends an installed copy's build to the shared cache, named by the crate" do
    expect(target_for(installed_copy)).to eq(File.join(cache, "hecks", "cargo-target", "host"))
  end

  it "lets CARGO_TARGET_DIR override an installed copy" do
    expect(target_for(installed_copy, "CARGO_TARGET_DIR" => "/tmp/own")).to eq("/tmp/own")
  end

  it "does not count a directory that only shares a prefix with a gem directory as installed" do
    expect(described_class.installed?("#{gems}-elsewhere/hecks")).to be(false)
  end
end

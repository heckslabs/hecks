require "spec_helper"
require "tmpdir"
require "fileutils"
require_relative "../../../lib/hecks/hecks/adapters/rust_workspace"

# An installed gem's Rust workspace is copied into the client project once; concurrent
# callers must never delete each other's copy.
RSpec.describe Hecks::Adapters::RustWorkspace do
  let(:tmp) { File.realpath(Dir.mktmpdir("rust_workspace")) }
  let(:gem_root) { File.join(tmp, "gem") }
  let(:app) { File.join(tmp, "app") }
  let(:space) { described_class.new(gem_root: gem_root, project_root: app, version: "9.9.9") }
  let(:target) { File.join(app, ".hecks", "rust", "9.9.9") }

  before do
    FileUtils.mkdir_p(File.join(gem_root, "rust", "src"))
    File.write(File.join(gem_root, "rust", "Cargo.toml"), "[features]\ndefault = []\n")
    File.write(File.join(gem_root, "rust", "src", "lib.rs"), "// kernel\n")
  end

  after { FileUtils.rm_rf(tmp) }

  it "makes the copy and marks it complete", :aggregate_failures do
    expect(space.directory).to eq(target)
    expect(File.exist?(File.join(target, described_class::MARKER))).to be(true)
    expect(File.exist?(File.join(target, "src", "lib.rs"))).to be(true)
  end

  it "leaves no staging directory beside the copy" do
    space.directory

    expect(Dir.children(File.dirname(target))).to eq(["9.9.9"])
  end

  it "redoes a copy an interrupted run left without the marker", :aggregate_failures do
    FileUtils.mkdir_p(File.join(target, "src"))
    File.write(File.join(target, "src", "partial.rs"), "half")

    space.directory

    expect(File.exist?(File.join(target, "src", "partial.rs"))).to be(false)
    expect(File.exist?(File.join(target, described_class::MARKER))).to be(true)
  end

  # A second process finishes first, and leaves a file the loser must not delete.
  def finish_copy_in_another_process
    FileUtils.mkdir_p(target)
    File.write(File.join(target, described_class::MARKER), "9.9.9\n")
    File.write(File.join(target, "winner.txt"), "mine")
  end

  def lose_the_race_to_publish
    allow(space).to receive(:build).and_wrap_original do |original, source, staging|
      original.call(source, staging)
      finish_copy_in_another_process
    end
  end

  it "keeps another process's finished copy when it loses the race to publish", :aggregate_failures do
    lose_the_race_to_publish

    expect(space.directory).to eq(target)
    expect(File.read(File.join(target, "winner.txt"))).to eq("mine")
    expect(Dir.children(File.dirname(target))).to eq(["9.9.9"])
  end
end

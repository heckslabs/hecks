require "spec_helper"
require "tmpdir"
require "fileutils"
require "digest"
require "hecks/rust_build/prebuilt_binary"

# A binary is published under a key that names what went into it, and a client downloads it only
# when the bytes match the hash published beside it. Anything short of that is a miss, and a miss
# means the caller compiles (ADR 0110).
RSpec.describe Hecks::RustBuild::PrebuiltBinary do
  let(:crate) { Dir.mktmpdir("prebuilt_crate") }
  let(:out) { File.join(Dir.mktmpdir("prebuilt_out"), "release", "bootstrap") }
  let(:target) { described_class.row("host")["target"] }

  after do
    FileUtils.rm_rf(crate)
    FileUtils.rm_rf(File.dirname(out, 2))
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(File.join(crate, path)))
    File.write(File.join(crate, path), text)
  end

  describe ".key" do
    before do
      write("Cargo.toml", "[package]")
      write("src/main.rs", "fn main() {}")
    end

    it "is the same for the same bytes, wherever they are checked out" do
      other = Dir.mktmpdir("prebuilt_other")
      FileUtils.cp_r(File.join(crate, "."), other)

      expect(described_class.key(other)).to eq(described_class.key(crate))
    ensure
      FileUtils.rm_rf(other)
    end

    it "changes when a source file changes" do
      before = described_class.key(crate)
      write("src/main.rs", "fn main() { println!(); }")

      expect(described_class.key(crate)).not_to eq(before)
    end

    it "does not change for Cargo's output or the crate's tests", :aggregate_failures do
      before = described_class.key(crate)
      write("target/release/bootstrap", "binary")
      write("tests/fixture.rb", "x")

      expect(described_class.key(crate)).to eq(before)
    end

    it "changes when a file is renamed, though its bytes are the same" do
      before = described_class.key(crate)
      FileUtils.mv(File.join(crate, "src/main.rs"), File.join(crate, "src/bin.rs"))

      expect(described_class.key(crate)).not_to eq(before)
    end
  end

  describe ".fetch" do
    let(:body) { "ELF-bytes" }
    let(:digest) { Digest::SHA256.hexdigest(body) }

    before { write("Cargo.toml", "[package]") }

    def answer(sha:, binary: body)
      allow(described_class).to receive(:get) do |url|
        url.end_with?(".sha256") ? "#{sha}  bootstrap-#{target}\n" : binary
      end
    end

    it "writes the binary, executable, when its hash matches", :aggregate_failures do
      answer(sha: digest)

      expect(described_class.fetch("host", crate, target: target, into: out)).to eq(out)
      expect(File.binread(out)).to eq(body)
      expect(File.executable?(out)).to be(true)
    end

    it "asks for the release named by the crate's key" do
      answer(sha: digest)
      described_class.fetch("host", crate, target: target, into: out)

      expect(described_class).to have_received(:get)
        .with(%r{/releases/download/host-#{described_class.key(crate)}/bootstrap-#{target}\.sha256\z})
    end

    it "is a miss when the bytes do not match the published hash, and writes nothing", :aggregate_failures do
      answer(sha: digest, binary: "tampered")

      expect(described_class.fetch("host", crate, target: target, into: out)).to be_nil
      expect(File.exist?(out)).to be(false)
    end

    it "is a miss when nothing is published" do
      allow(described_class).to receive(:get).and_return(nil)

      expect(described_class.fetch("host", crate, target: target, into: out)).to be_nil
    end

    it "is a miss for a target the row does not publish" do
      answer(sha: digest)

      expect(described_class.fetch("host", crate, target: "aarch64-apple-darwin", into: out)).to be_nil
    end

    it "does not download when HECKS_PREBUILT is off" do
      answer(sha: digest)
      stub_const("ENV", ENV.to_h.merge("HECKS_PREBUILT" => "off"))

      expect(described_class.fetch("host", crate, target: target, into: out)).to be_nil
    end
  end

  it "has a row for the host, which is what the publish workflow is projected from" do
    expect(described_class.row("host")).to include("crate" => "rust/host", "bin" => "bootstrap")
  end
end

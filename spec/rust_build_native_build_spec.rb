require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/rust_build"
require "hecks/rust_build/native_build"

# The native build is cached per workspace, feature and generated sources, so regenerating a
# domain never answers with an older binary or an older failure.
RSpec.describe Hecks::RustBuild::NativeBuild do
  let(:dir) { Dir.mktmpdir("native_build") }

  before do
    File.write(File.join(dir, "Cargo.toml"), "[features]\npizzas = []\n")
    FileUtils.mkdir_p(File.join(dir, "src", "generated"))
    File.write(File.join(dir, "src", "generated", "pizzas.rs"), "// one\n")
    described_class.cache.clear
  end

  after do
    FileUtils.rm_rf(dir)
    described_class.cache.clear
  end

  def regenerate(text)
    path = File.join(dir, "src", "generated", "pizzas.rs")
    File.write(path, text)
    File.utime(Time.now + 5, Time.now + 5, path)
  end

  def add_build_noise
    FileUtils.mkdir_p(File.join(dir, "target"))
    File.write(File.join(dir, "target", "noise.rs"), "x")
  end

  def stub_builds(*results)
    queue = results.each
    allow(described_class).to receive(:build_and_pin) do
      result = queue.next
      raise result if result.is_a?(Exception)

      result
    end
  end

  it "builds once while the sources stay the same" do
    allow(described_class).to receive(:build_and_pin).and_return("bin-1")

    2.times { described_class.build_rust_for("pizzas", dir) }

    expect(described_class).to have_received(:build_and_pin).once
  end

  it "builds again after the generated sources change" do
    builds = %w[bin-1 bin-2].each
    allow(described_class).to receive(:build_and_pin) { builds.next }

    first = described_class.build_rust_for("pizzas", dir)
    regenerate("// two, longer\n")

    expect([first, described_class.build_rust_for("pizzas", dir)]).to eq(%w[bin-1 bin-2])
  end

  it "does not keep a failure once the sources change", :aggregate_failures do
    stub_builds(described_class::BuildFailed.new("broken"), "bin-2")

    expect { described_class.build_rust_for("pizzas", dir) }.to raise_error(described_class::BuildFailed)
    expect { described_class.build_rust_for("pizzas", dir) }.to raise_error(described_class::BuildFailed, "broken")
    regenerate("// fixed\n")

    expect(described_class.build_rust_for("pizzas", dir)).to eq("bin-2")
  end

  it "ignores files under target/" do
    allow(described_class).to receive(:build_and_pin).and_return("bin-1")
    described_class.build_rust_for("pizzas", dir)
    add_build_noise
    described_class.build_rust_for("pizzas", dir)

    expect(described_class).to have_received(:build_and_pin).once
  end

  describe "a binary pinned ahead of the build" do
    let(:pinned) { File.join(dir, "target", "debug", "rust-pizzas") }

    def pin_binary(mtime)
      FileUtils.mkdir_p(File.dirname(pinned))
      File.write(pinned, "binary")
      File.chmod(0o755, pinned)
      File.utime(mtime, mtime, pinned)
    end

    def stub_cargo_leaving_a_binary
      allow(described_class).to receive(:cargo) do
        File.write(File.join(dir, "target", "debug", "rust"), "built")
        File.chmod(0o755, File.join(dir, "target", "debug", "rust"))
      end
    end

    it "is used as it is when every source predates it" do
      pin_binary(Time.now + 60)
      allow(described_class).to receive(:cargo)

      expect(described_class.build_rust_for("pizzas", dir)).to eq(pinned)
    end

    it "is not rebuilt by cargo when every source predates it" do
      pin_binary(Time.now + 60)
      allow(described_class).to receive(:cargo)
      described_class.build_rust_for("pizzas", dir)

      expect(described_class).not_to have_received(:cargo)
    end

    it "is rebuilt when a source is newer than it" do
      pin_binary(Time.now - 60)
      stub_cargo_leaving_a_binary
      described_class.build_rust_for("pizzas", dir)

      expect(described_class).to have_received(:cargo).once
    end
  end
end

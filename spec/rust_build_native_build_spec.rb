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

  it "builds once while the sources stay the same" do
    expect(described_class).to receive(:build_and_pin).once.and_return("bin-1")

    2.times { described_class.build_rust_for("pizzas", dir) }
  end

  it "builds again after the generated sources change" do
    builds = %w[bin-1 bin-2].each
    allow(described_class).to receive(:build_and_pin) { builds.next }

    first = described_class.build_rust_for("pizzas", dir)
    regenerate("// two, longer\n")

    expect([first, described_class.build_rust_for("pizzas", dir)]).to eq(%w[bin-1 bin-2])
  end

  it "does not keep a failure once the sources change" do
    results = [described_class::BuildFailed.new("broken"), "bin-2"].each
    allow(described_class).to receive(:build_and_pin) do
      result = results.next
      raise result if result.is_a?(Exception)

      result
    end

    expect { described_class.build_rust_for("pizzas", dir) }.to raise_error(described_class::BuildFailed)
    expect { described_class.build_rust_for("pizzas", dir) }.to raise_error(described_class::BuildFailed, "broken")
    regenerate("// fixed\n")

    expect(described_class.build_rust_for("pizzas", dir)).to eq("bin-2")
  end

  it "ignores files under target/" do
    expect(described_class).to receive(:build_and_pin).once.and_return("bin-1")
    described_class.build_rust_for("pizzas", dir)
    FileUtils.mkdir_p(File.join(dir, "target"))
    File.write(File.join(dir, "target", "noise.rs"), "x")

    described_class.build_rust_for("pizzas", dir)
  end
end

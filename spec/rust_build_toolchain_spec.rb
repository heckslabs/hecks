# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/rust_build"

# Every Rust build child finds rustup's `cargo` first, and a build that fails for an old `cargo`
# says so. The cargo programs here are stand-in scripts: no rustup or Homebrew is involved.
RSpec.describe Hecks::RustBuild::Toolchain do
  let(:dir) { Dir.mktmpdir("toolchain") }
  let(:rustup) { File.join(dir, "cargo-home", "bin") }
  let(:brew) { File.join(dir, "brew", "bin") }
  let(:base) { { "CARGO_HOME" => File.join(dir, "cargo-home"), "PATH" => "#{brew}:/usr/bin" } }

  after { FileUtils.rm_rf(dir) }

  def fake_cargo(bin, version)
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "cargo"), "#!/bin/sh\necho 'cargo #{version} (stand-in)'\n")
    File.chmod(0o755, File.join(bin, "cargo"))
  end

  def pin(channel)
    File.write(File.join(dir, "rust-toolchain.toml"), %([toolchain]\nchannel = "#{channel}"\n))
  end

  it "puts rustup's proxy directory before Homebrew's cargo" do
    fake_cargo(rustup, "1.98.0")

    expect(described_class.environment(base)["PATH"]).to eq("#{rustup}:#{brew}:/usr/bin")
  end

  it "changes nothing when rustup is first, absent, or the base names no PATH", :aggregate_failures do
    expect(described_class.environment(base)).to eq({})
    fake_cargo(rustup, "1.98.0")
    expect(described_class.environment(base.merge("PATH" => "#{rustup}:#{brew}"))["PATH"]).to eq("#{rustup}:#{brew}")
    expect(described_class.environment("CARGO_HOME" => File.join(dir, "cargo-home"))).to eq({})
  end

  it "leaves a RUSTUP_TOOLCHAIN the caller set alone" do
    fake_cargo(rustup, "1.98.0")

    expect(described_class.environment(base.merge("RUSTUP_TOOLCHAIN" => "nightly"))).not_to include("RUSTUP_TOOLCHAIN")
  end

  it "reads the channel the checkout pins" do
    pin("1.98.0")

    expect(described_class.pinned(dir)).to eq("1.98.0")
  end

  it "names the cargo path and version when an old cargo cannot build the source", :aggregate_failures do
    fake_cargo(brew, "1.94.0")
    pin("1.98.0")
    note = described_class.failure("error[E0658]: use of unstable library feature", root: dir, env: base)

    expect(note).to include("toolchain failure", File.join(brew, "cargo"), "1.94.0", "1.98.0")
  end

  it "says nothing for other errors or a cargo at the pin", :aggregate_failures do
    fake_cargo(brew, "1.98.0")
    pin("1.98.0")

    expect(described_class.failure("error[E0658]: x", root: dir, env: base)).to be_nil
    expect(described_class.failure("error: expected `;`", root: dir, env: base)).to be_nil
  end
end

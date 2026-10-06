require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/rust_build"
require "hecks/rust_build/host"

# The host build compiles `rust/host` from the workspace and stages it with the domain's module and
# IR. Cargo and rustup are stubbed, so what is asked of them, what is staged and what is refused
# are tested without a toolchain.
RSpec.describe Hecks::RustBuild::Host do
  let(:dir) { File.realpath(Dir.mktmpdir("host_build")) }
  let(:workspace) { File.join(dir, "rust") }
  let(:stage) { File.join(dir, "stage") }
  let(:installed) { "aarch64-apple-darwin\naarch64-unknown-linux-gnu\nwasm32-wasip1\n" }
  let(:cargo_calls) { [] }

  before do
    FileUtils.mkdir_p(File.join(workspace, "host"))
    FileUtils.mkdir_p(File.join(workspace, "dist"))
    File.write(File.join(workspace, "dist", "shelf.wasm"), "wasm")
    File.write(File.join(workspace, "dist", "shelf.ir.json"), "{}")
    allow(described_class).to receive(:puts)
    allow(described_class).to receive(:query) do |*command|
      case command.take(3)
      in ["rustup", "--version", *] then "rustup 1.0\n"
      in ["rustup", "run", *] then "host: aarch64-apple-darwin\n"
      in ["rustup", "target", *] then installed
      else nil
      end
    end
    allow(Hecks::RustBuild::Wasm).to receive(:call).and_return(0)
    allow(Hecks::RustBuild).to receive(:command!) do |*command, **options|
      cargo_calls << [command, options]
      target = command[command.index("--target") + 1]
      built = File.join(options[:env].fetch("CARGO_TARGET_DIR"), target, "release")
      FileUtils.mkdir_p(built)
      File.write(File.join(built, "bootstrap"), "host binary for #{target}")
    end
  end

  after { FileUtils.rm_rf(dir) }

  def build(*args, **env)
    Hecks::RustBuild.with_env({ "HECKS_RUST_DIR" => workspace, "CARGO_TARGET_DIR" => nil }.merge(env)) do
      described_class.call(["domains/shelf", *args, "--stage=#{stage}"])
    end
  end

  it "stages the host, the module and the IR under the domain's name, for the machine's own target", :aggregate_failures do
    expect(build).to eq(0)

    expect(Dir.children(stage).sort).to eq(%w[shelf-host shelf.ir.json shelf.wasm])
    expect(File.read(File.join(stage, "shelf-host"))).to eq("host binary for aarch64-apple-darwin")
    expect(File.executable?(File.join(stage, "shelf-host"))).to be(true)
  end

  RUST_HOST_CROSS_CARGO = ["rustup", "run", "stable", "cargo", "build", "--release", "--target", "aarch64-unknown-linux-gnu",
                           "--bin", "bootstrap"].freeze

  it "builds the module first" do
    build("--target=aarch64-unknown-linux-gnu", "CARGO_TARGET_DIR" => File.join(dir, "cache"))

    expect(Hecks::RustBuild::Wasm).to have_received(:call).with(["domains/shelf"])
  end

  it "then compiles rust/host in release for the target, writing to the target dir", :aggregate_failures do
    build("--target=aarch64-unknown-linux-gnu", "CARGO_TARGET_DIR" => File.join(dir, "cache"))
    command, options = cargo_calls.fetch(0)

    expect(command).to eq(RUST_HOST_CROSS_CARGO)
    expect(options[:chdir]).to eq(File.join(workspace, "host"))
    expect(options[:env]).to include("CARGO_TARGET_DIR" => File.join(dir, "cache"))
  end

  it "keeps Cargo's output beside the host crate when no target dir is named, so a second build is incremental" do
    build

    expect(cargo_calls.fetch(0).last[:env]).to include("CARGO_TARGET_DIR" => File.join(workspace, "host", "target"))
  end

  it "defaults the stage to .hecks/host/<target> under the working directory" do
    Dir.chdir(dir) do
      Hecks::RustBuild.with_env("HECKS_RUST_DIR" => workspace) { described_class.call(["domains/shelf"]) }
    end

    expect(File.exist?(File.join(dir, ".hecks", "host", "aarch64-apple-darwin", "shelf-host"))).to be(true)
  end

  it "links a cross target with the cross compiler on PATH" do
    allow(described_class).to receive(:query).with("aarch64-linux-gnu-gcc", "--version").and_return("gcc\n")

    build("--target=aarch64-unknown-linux-gnu", "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER" => nil)

    expect(cargo_calls.fetch(0).last[:env])
      .to include("CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER" => "aarch64-linux-gnu-gcc")
  end

  context "when the target is not installed" do
    let(:installed) { "aarch64-apple-darwin\n" }

    it "refuses with the exact rustup command, before building anything", :aggregate_failures do
      allow(Hecks::RustBuild::Wasm).to receive(:call).and_raise("the module was built")
      expect { build("--target=aarch64-unknown-linux-gnu") }
        .to raise_error(Hecks::RustBuild::Failure,
                        /rustup target add aarch64-unknown-linux-gnu --toolchain stable/)
      expect(cargo_calls).to be_empty
    end
  end

  it "refuses a wasm target, which a server binary is not built for" do
    expect { build("--target=wasm32-unknown-unknown") }
      .to raise_error(Hecks::RustBuild::Failure, /wasm target.*build\.build_wasm/)
  end

  it "refuses a target that is not a triple" do
    expect { build("--target=arm64") }.to raise_error(Hecks::RustBuild::Failure, /not a Rust target triple/)
  end

  it "refuses when rustup is not installed" do
    allow(described_class).to receive(:query).and_return(nil)

    expect { build }.to raise_error(Hecks::RustBuild::Failure, %r{rustup isn't installed.*https://rustup\.rs})
  end

  it "stops with the module's refusal and builds no host when the module does not build", :aggregate_failures do
    allow(Hecks::RustBuild::Wasm).to receive(:call).and_raise(Hecks::RustBuild::Failure, "wasm32-wasip1 isn't installed")

    expect { build }.to raise_error(Hecks::RustBuild::Failure, /wasm32-wasip1 isn't installed/)
    expect(cargo_calls).to be_empty
    expect(Dir.exist?(stage)).to be(false)
  end

  it "names the linker a cross build needs when Cargo fails" do
    allow(Hecks::RustBuild).to receive(:command!).and_raise(Hecks::RustBuild::Failure, "`cargo build` failed")

    expect { build("--target=aarch64-unknown-linux-gnu") }
      .to raise_error(Hecks::RustBuild::Failure, /linker for it.*CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER/m)
  end

  it "refuses when the build leaves no IR beside the module" do
    FileUtils.rm(File.join(workspace, "dist", "shelf.ir.json"))

    expect { build }.to raise_error(Hecks::RustBuild::Failure, /left no .*shelf\.ir\.json/)
  end

  it "refuses without a domain" do
    expect { described_class.call([]) }.to raise_error(Hecks::RustBuild::Failure, /usage: hecks build_host/)
  end
end

require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/rust_build"
require "hecks/rust_build/wasm_browser"

# The browser build regenerates a domain in a scratch copy, so a checkout's tracked
# `rust/src/generated/` and `Cargo.toml` are never rewritten.
RSpec.describe Hecks::RustBuild::WasmBrowser do
  let(:dir) { File.realpath(Dir.mktmpdir("wasm_browser")) }

  before do
    FileUtils.mkdir_p(File.join(dir, "src"))
    FileUtils.mkdir_p(File.join(dir, "web", "src"))
    FileUtils.mkdir_p(File.join(dir, "web", "target"))
    File.write(File.join(dir, "Cargo.toml"), "[features]\ndefault = []\n")
    File.write(File.join(dir, "Cargo.lock"), "")
    File.write(File.join(dir, "src", "lib.rs"), "// kernel\n")
    File.write(File.join(dir, "web", "Cargo.toml"), "[package]\n")
    File.write(File.join(dir, "web", "src", "lib.rs"), "// web\n")
    allow(described_class).to receive_messages(require_target!: nil, require_cli!: nil)
    allow(described_class).to receive(:puts)
  end

  after { FileUtils.rm_rf(dir) }

  it "generates in a scratch workspace and builds the web crate there, leaving the workspace untouched" do
    generated_in = nil
    allow(Hecks::RustBuild::ProjectRust).to receive(:call) do
      generated_in = ENV.fetch("HECKS_RUST_DIR")
      FileUtils.mkdir_p(File.join(generated_in, "src", "generated"))
      0
    end
    built = []
    allow(Hecks::RustBuild).to receive(:command!) { |*command, **options| built << [command.first, options] }

    Hecks::RustBuild.with_env("HECKS_RUST_DIR" => dir) { described_class.call(["examples/pizzas"]) }

    expect(generated_in).to eq(File.join(dir, "scratch", "project_wasm_browser"))
    expect(Dir.exist?(File.join(dir, "src", "generated"))).to be(false)
    cargo = built.first.last
    expect(cargo[:chdir]).to eq(File.join(generated_in, "web"))
    expect(cargo[:env]).to eq("CARGO_TARGET_DIR" => File.join(dir, "web", "target"))
    expect(File.exist?(File.join(generated_in, "web", "src", "lib.rs"))).to be(true)
    expect(Dir.exist?(File.join(generated_in, "web", "target"))).to be(false)
  end

  it "refuses with the reason when generation fails, before building anything" do
    allow(Hecks::RustBuild::ProjectRust).to receive(:call).and_return(1)
    expect(Hecks::RustBuild).not_to receive(:command!)

    expect { Hecks::RustBuild.with_env("HECKS_RUST_DIR" => dir) { described_class.call(["examples/pizzas"]) } }
      .to raise_error(Hecks::RustBuild::Failure, /project_rust failed/)
  end
end

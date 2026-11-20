require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/rust_build/component"

# A temporary checkout holding a crate under `rust/adapters/mailer` and its committed component
# beside the `.adapter` file that would run it, under `lib/hecks/adapters/driven/mailer`.
module ComponentCheckout
  def committed = File.join(checkout, "lib", "hecks", "adapters", "driven", "mailer")

  def lay_out
    crate = File.join(checkout, "rust", "adapters", "mailer")
    FileUtils.mkdir_p([crate, committed])
    File.write(File.join(crate, "Cargo.toml"), "[package]\n")
    File.write(File.join(committed, "mailer.wasm"), "component bytes")
  end

  def check(name = "mailer")
    Hecks::RustBuild.in_workspace(File.join(checkout, "rust")) { described_class.call([name, "--check"]) }
  end

  def record_digest(of: "component bytes")
    File.write(File.join(committed, "mailer.wasm.sha256"),
               "#{format(described_class::BANNER, "mailer")}\n#{Digest::SHA256.hexdigest(of)}  mailer.wasm\n")
  end
end

# The build_component tool's check mode compares a committed adapter component, kept beside the
# `.adapter` file that runs it, with its digest file. No toolchain is needed.
RSpec.describe Hecks::RustBuild::Component do
  include ComponentCheckout

  let(:checkout) { Dir.mktmpdir("rust_build_component") }

  before { lay_out }
  after { FileUtils.rm_rf(checkout) }

  it "passes a component that matches its digest file" do
    record_digest
    expect { check }.to output(/mailer.wasm matches its digest/).to_stdout
  end

  it "refuses a component its digest file does not name" do
    record_digest(of: "an older build")
    expect { check }.to raise_error(Hecks::RustBuild::Failure, /does not match mailer.wasm.sha256/)
  end

  it "refuses a component with no digest file" do
    expect { check }.to raise_error(Hecks::RustBuild::Failure, /has no digest file/)
  end

  it "refuses a crate that is not under rust/adapters" do
    expect { check("missing") }.to raise_error(Hecks::RustBuild::Failure, /no adapter crate/)
  end
end

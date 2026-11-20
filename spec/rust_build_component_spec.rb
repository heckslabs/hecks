require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/rust_build/component"

# The build_component tool's check mode compares a committed adapter component with its digest
# file. Each example writes a crate into a temporary workspace, so no toolchain is needed.
RSpec.describe Hecks::RustBuild::Component do
  let(:workspace) { Dir.mktmpdir("rust_build_component") }
  let(:crate) { File.join(workspace, "adapters", "mailer") }

  before do
    FileUtils.mkdir_p(crate)
    File.write(File.join(crate, "Cargo.toml"), "[package]\n")
    File.write(File.join(crate, "mailer.wasm"), "component bytes")
  end

  after { FileUtils.rm_rf(workspace) }

  def check(name = "mailer")
    Hecks::RustBuild.in_workspace(workspace) { described_class.call([name, "--check"]) }
  end

  def record_digest(of: "component bytes")
    File.write(File.join(crate, "mailer.wasm.sha256"),
               "#{format(described_class::BANNER, "mailer")}\n#{Digest::SHA256.hexdigest(of)}  mailer.wasm\n")
  end

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

require "spec_helper"
require "tmpdir"
require "hecks/rust_build"

# A build child shares one compiler cache across work items when `sccache` is installed, so a
# worktree's slot reuses what another built; a machine without it builds as before.
RSpec.describe Hecks::RustBuild::CompilerCache do
  let(:bin) { Dir.mktmpdir }
  let(:base) { { "PATH" => "#{bin}:/usr/bin" } }

  after { FileUtils.remove_entry(bin) }

  def install_sccache
    path = File.join(bin, "sccache")
    File.write(path, "#!/bin/sh\n")
    File.chmod(0o755, path)
    path
  end

  it "wraps rustc in sccache and turns incremental off when sccache is installed", :aggregate_failures do
    path = install_sccache

    expect(described_class.environment(base)).to eq("RUSTC_WRAPPER" => path, "CARGO_INCREMENTAL" => "0")
  end

  it "adds nothing when sccache is not installed" do
    expect(described_class.environment(base)).to eq({})
  end

  it "leaves a wrapper set by hand alone, even an empty one" do
    install_sccache

    expect(described_class.environment(base.merge("RUSTC_WRAPPER" => ""))).to eq({})
  end

  it "reaches the environment a build child starts with", :aggregate_failures do
    path = install_sccache
    env = Hecks::RustBuild::SessionBuild.environment(root: bin, base: base)

    expect(env["RUSTC_WRAPPER"]).to eq(path)
    expect(env["CARGO_INCREMENTAL"]).to eq("0")
  end
end

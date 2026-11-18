# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/git_train"

# Builds the fake cargos and runs one drift check for the drift checks spec.
module DriftCheckHelpers
  # What the codegen build prints when a cargo older than the pin cannot compile it.
  BUILD_FAILED = <<~SH
    cargo build
    echo 'error[E0599]: no method named `map_or_default` found for enum `Option`'
    echo 'hecks project_rust: cargo build failed in rust/codegen -- run it there directly to see why'
    exit 1
  SH

  # Writes an executable `cargo` into +dir+ that prints +version+ and fails a build.
  def fake_cargo(dir, version)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "cargo")
    File.write(path, "#!/bin/sh\n[ \"$1\" = \"--version\" ] && echo 'cargo #{version}' && exit 0\nexit 101\n")
    File.chmod(0o755, path)
  end

  # An environment whose `PATH` holds Homebrew's cargo 1.94 first, with +proxy+ as rustup's.
  def base(proxy: nil)
    fake_cargo(File.join(@dir, "brew"), "1.94.0")
    fake_cargo(File.join(@dir, "rustup", "bin"), proxy) if proxy
    { "PATH" => "#{@dir}/brew:/usr/bin:/bin", "CARGO_HOME" => File.join(@dir, "rustup") }
  end

  # An environment with no cargo on its `PATH` and none where rustup would keep one.
  def bare = { "PATH" => "/usr/bin:/bin", "CARGO_HOME" => File.join(@dir, "none") }

  # @return [String, nil] the refusal the check raised, nil when it passed
  def refusal(script, env)
    guard = instance_double(Hecks::Adapters::GitTrain::BranchGuard, head: "abc123")
    Hecks::Adapters::GitTrain::DriftChecks.new(@dir, guard, [["sh", "-c", script]], base: env).run("abc123")
    nil
  rescue Hecks::Adapters::ConsoleCapture::Failure => e
    e.message
  end
end

# A drift check whose Cargo build fails before it compares is a failed build, never drift, and the
# check runs with rustup's cargo first whatever order the caller's `PATH` holds.
RSpec.describe Hecks::Adapters::GitTrain::DriftChecks, :io do
  include DriftCheckHelpers

  around do |example|
    Dir.mktmpdir("drift-checks") do |dir|
      @dir = dir
      example.run
    end
  end

  it "names a failed codegen build under the cargo it found, not as drift", :aggregate_failures do
    message = refusal(DriftCheckHelpers::BUILD_FAILED, base)

    expect(message).to include("could not compare: codegen build failed under cargo 1.94.0")
    expect(message).not_to include("found drift")
  end

  it "runs the check with rustup's cargo first whatever the caller's PATH order" do
    message = refusal("cargo --version; exit 1", base(proxy: "1.98.0"))

    expect(message).to include("cargo 1.98.0")
  end

  it "names a failed build under no cargo when none is on PATH and rustup has none" do
    expect(refusal(DriftCheckHelpers::BUILD_FAILED, bare)).to include("under a cargo not found on PATH")
  end

  it "still names a difference in the generated files as drift" do
    diff = "echo 'diff --git a/x.rs b/x.rs'; echo '+    error[E0599]: quoted'; exit 1"

    expect(refusal(diff, base)).to include("found drift; regenerate and commit it first")
  end

  it "names as drift a gate check that fails without building" do
    expect(refusal("echo 'ci_gates: 2 workflows are stale'; exit 1", base)).to include("found drift")
  end
end

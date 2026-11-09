require "spec_helper"
require "tmpdir"
require_relative "support/thread_parking"
require "hecks/rust_build/gate_build"

# A gate check that compiles Rust takes the machine-wide build lock, gets the job cap and `nice`,
# and builds into the shared target directory; any other check runs as it did. The checks here
# are stand-ins: no cargo runs.
RSpec.describe Hecks::RustBuild::GateBuild do
  let(:session) { Hecks::RustBuild::SessionBuild }
  let(:dir) { Dir.mktmpdir("gate-build") }
  let(:lock) { File.join(dir, "build.lock") }
  let(:clippy) { ["sh", "-ec", "for crate in . host; do\n  cargo clippy --manifest-path \"rust/$crate/Cargo.toml\"\ndone"] }
  let(:status) { instance_double(Process::Status, success?: true) }

  before do
    allow(Open3).to receive(:capture2e).and_return(["", status])
    allow(session).to receive(:environment)
      .and_return("CARGO_BUILD_JOBS" => "4", "CARGO_TARGET_DIR" => "/shared")
    allow(session).to receive(:command) { |words, **| ["nice", "-n", "15", *words] }
  end

  after { FileUtils.rm_rf(dir) }

  def capture(run, env: {}, base: {})
    described_class.capture(run, env, dir, base: base, lock: lock)
  end

  it "knows a script that names cargo or rustc, and not one that only mentions it in a comment", :aggregate_failures do
    expect(described_class.compiles?(clippy)).to be(true)
    expect(described_class.compiles?(["sh", "-ec", "# cargo is slow\nbundle exec rubocop"])).to be(false)
    expect(described_class.compiles?(%w[cargo test])).to be(true)
    expect(described_class.compiles?(%w[bundle exec rubocop])).to be(false)
  end

  it "builds into the worktree's own slot, never the shared directory itself" do
    capture(clippy)

    expect(session).to have_received(:environment).with(root: dir, base: {}, binary: true)
  end

  it "runs a compiling check under nice, with the job cap and the target the policy names" do
    capture(clippy)

    expect(Open3).to have_received(:capture2e).with(
      hash_including("CARGO_BUILD_JOBS" => "4", "CARGO_TARGET_DIR" => "/shared"),
      "nice", "-n", "15", *clippy, chdir: dir
    )
  end

  it "holds the build lock while the check runs" do
    allow(Open3).to receive(:capture2e) { [File.read(lock), status] }

    expect(capture(clippy).first).to eq(Process.pid.to_s)
  end

  it "marks the check's own children as holders, so a hecks build inside it does not wait" do
    capture(clippy)

    expect(Open3).to have_received(:capture2e)
      .with(hash_including(Hecks::RustBuild::BuildLock::HELD => Process.pid.to_s), any_args)
  end

  it "runs a check that does not compile as it was, without the lock or the policy", :aggregate_failures do
    capture(%w[bundle exec rubocop], env: { "A" => "1" })

    expect(Open3).to have_received(:capture2e).with({ "A" => "1" }, "bundle", "exec", "rubocop", chdir: dir)
    expect(File.exist?(lock)).to be(false)
  end

  it "lets the stage's own environment win over the policy" do
    capture(clippy, env: { "CARGO_BUILD_JOBS" => "1" })

    expect(Open3).to have_received(:capture2e).with(hash_including("CARGO_BUILD_JOBS" => "1"), any_args)
  end

  it "skips the lock in CI and with HECKS_NO_BUILD_LOCK=1, and still applies the policy", :aggregate_failures do
    capture(clippy, base: { "CI" => "1" })
    capture(clippy, base: { "HECKS_NO_BUILD_LOCK" => "1" })

    expect(File.exist?(lock)).to be(false)
    expect(Open3).to have_received(:capture2e).twice.with(hash_including("CARGO_BUILD_JOBS" => "4"), any_args)
  end

  # Runs a compiling check on a thread while this one holds the lock: how many times the check had
  # started once its thread was blocked, and how many once the lock was let go.
  def starts_while_held_and_after
    starts = []
    allow(Open3).to receive(:capture2e) { starts.push(:started) && ["", status] }
    thread = nil
    during = Hecks::RustBuild::BuildLock.hold(base: {}, file: lock, err: StringIO.new) do
      thread = Thread.new { capture(clippy) }
      ThreadParking.wait_until_parked(thread)
      starts.size
    end
    [during, thread.join && starts.size]
  end

  it "makes a second compiling check wait for the first" do
    expect(starts_while_held_and_after).to eq([0, 1])
  end
end

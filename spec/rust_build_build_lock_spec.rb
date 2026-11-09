require "spec_helper"
require "tmpdir"
require "hecks/rust_build/build_lock"

# One Rust build at a time on the machine: a build waits for the lock another holds, says whom it
# waits for, and never waits for a lock its own parent holds.
RSpec.describe Hecks::RustBuild::BuildLock do
  let(:dir) { Dir.mktmpdir("build-lock") }
  let(:file) { File.join(dir, "build.lock") }
  let(:err) { StringIO.new }

  after { FileUtils.rm_rf(dir) }

  def hold(base: {}, **options, &block)
    described_class.hold(base: base, err: err, file: file, **options, &block)
  end

  # A clock that moves a second each time it is asked, and a pause that never sleeps.
  def ticking = { clock: [0, 1, 2, 3, 4, 5, 6, 7, 8].each.method(:next).to_proc, pause: ->(_seconds) {} }

  it "runs the block and hands it the variable that marks its child as holding the lock" do
    expect(hold { |held| held }).to eq(described_class::HELD => Process.pid.to_s)
  end

  it "writes the holder's pid into the lock file while it holds it" do
    expect(hold { File.read(file) }).to eq(Process.pid.to_s)
  end

  it "does not wait for a lock its parent holds", :aggregate_failures do
    outer = hold { hold { |held| held } }

    expect(outer).to eq(described_class::HELD => Process.pid.to_s)
    expect(err.string).to be_empty
  end

  it "is skipped when the environment says a parent holds it" do
    expect(hold(base: { described_class::HELD => "123" }) { |held| held }).to eq({})
  end

  it "is skipped with HECKS_NO_BUILD_LOCK=1 and in CI", :aggregate_failures do
    expect(hold(base: { "HECKS_NO_BUILD_LOCK" => "1" }) { |held| held }).to eq({})
    expect(hold(base: { "CI" => "true" }) { |held| held }).to eq({})
  end

  it "runs the block without the lock when the lock file cannot be opened" do
    unwritable = File.join(__FILE__, "build.lock")

    expect(described_class.hold(base: {}, err: err, file: unwritable) { |held| held }).to eq({})
  end

  describe "when another process holds it" do
    let(:other) { File.open(file, File::CREAT | File::RDWR) }

    before do
      other.flock(File::LOCK_EX)
      other.write("4242")
      other.flush
    end

    after { other.close }

    it "says whom it waits for once the wait passes five seconds, and builds after giving up", :aggregate_failures do
      stub_const("Hecks::RustBuild::BuildLock::GIVE_UP_AFTER", 8)

      result = hold(**ticking) { :built }

      expect(result).to eq(:built)
      expect(err.string).to include("waiting for another Rust build (pid 4242)", "building anyway")
    end

    it "says so only once", :aggregate_failures do
      stub_const("Hecks::RustBuild::BuildLock::GIVE_UP_AFTER", 8)
      hold(**ticking) { :built }

      expect(err.string.scan("hecks: waiting for another Rust build").size).to eq(1)
    end
  end

  describe ".building" do
    it "holds the lock for a command that compiles, directly or under rustup", :aggregate_failures do
      expect(described_class.compiles?(%w[cargo build])).to be(true)
      expect(described_class.compiles?(%w[rustup run stable cargo build])).to be(true)
    end

    it "runs any other command without the lock" do
      expect(described_class.building(%w[wasm-bindgen --version]) { |held| held }).to eq({})
    end
  end
end

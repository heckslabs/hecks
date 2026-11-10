require "spec_helper"
require "json"
require "rbconfig"
require "hecks/rust_build"
require "hecks/rust_build/prune"
require "hecks/hecks/adapters/main_verification"

# Run in the child, as a check's command is: it starts a grandchild, as the test runner starts a
# spec file, and reports what that grandchild finds.
CLONE_ENVIRONMENT_PROBE = <<~RUBY.freeze
  require "open3"; require "json"
  bundler, = Open3.capture2(RbConfig.ruby, "-e", "print defined?(Bundler).inspect")
  cargo = ENV["PATH"].split(":").map { |dir| File.join(dir, "cargo") }.find { |path| File.executable?(path) }
  print JSON.generate(bundler: bundler, cargo: cargo)
RUBY

# The environment a verification's checks run with, read from a real child the command runner
# starts, not a stub: the launcher runs under Bundler as CI runs it, so a spec's own subprocess
# loads Bundler, and the `cargo` a build finds is rustup's, so the pinned toolchain applies.
RSpec.describe "the environment of a verification's checks" do
  let(:checks) { Hecks::Adapters::MainIntegration::Checks }
  let(:toolchain) { Hecks::Adapters::MainIntegration::Toolchain }

  def child
    argv = [*checks::RUNS_AS, RbConfig.ruby, "-e", CLONE_ENVIRONMENT_PROBE]
    ok, output = Hecks::Adapters::MainIntegration::CommandRunner.new.call(argv, chdir: Hecks::RustBuild::ROOT)
    ok ? JSON.parse(output) : raise("the probe failed:\n#{output}")
  end

  it "gives a spec's own subprocess Bundler, as `bundle exec` does on CI" do
    expect(child["bundler"]).to eq('"constant"')
  end

  it "finds rustup's cargo first, so rust-toolchain.toml picks the compiler" do
    skip "no rustup cargo on this machine (#{toolchain.proxies})" if toolchain.environment.empty?

    expect(child["cargo"]).to eq(File.join(toolchain.proxies, "cargo"))
  end

  it "runs every launcher command of a verification under Bundler" do
    commands = checks.new(Hecks::RustBuild::ROOT, []).all.map(&:last)
    expect(commands.map { |argv| argv.first(checks::RUNS_AS.size) }.uniq).to eq([checks::RUNS_AS])
  end

  def bounded_check(script, bound: 60)
    runner = Hecks::Adapters::MainIntegration::CommandRunner.new(bound: bound)
    runner.call([RbConfig.ruby, "-e", script], chdir: Hecks::RustBuild::ROOT)
  end

  it "never hands a check the opt-in to specs that reach a live service" do
    ENV["HECKS_LIVE_SERVICES"] = "cloudfront"
    expect(bounded_check("print ENV.key?('HECKS_LIVE_SERVICES')")).to eq([true, "false"])
  ensure
    ENV.delete("HECKS_LIVE_SERVICES")
  end

  it "ends a check that runs past its bound and says so", :aggregate_failures do
    ok, output = bounded_check("sleep 30", bound: 1)
    expect(ok).to be(false)
    expect(output).to include("ran past the 1-second bound (spec_bounds check_seconds)")
  end

  it "puts rustup's proxies ahead of a cargo earlier on PATH" do
    skip "no rustup cargo on this machine (#{toolchain.proxies})" if toolchain.environment.empty?

    path = toolchain.environment("PATH" => "/opt/homebrew/bin:#{toolchain.proxies}")["PATH"]
    expect(path).to eq("#{toolchain.proxies}:/opt/homebrew/bin")
  end

  # Where the checks build Rust, read from fake clean copies: a directory each, at a new path,
  # pinning a toolchain the way `rust-toolchain.toml` does and holding one crate.
  describe "the cargo targets of a clean copy" do
    let(:target) { Hecks::Adapters::MainIntegration::CargoTarget }
    let(:scratch) { Dir.mktmpdir("cargo-target-spec") }
    let(:shared) { File.join(scratch, "shared") }

    before { allow(Hecks::RustBuild::TargetDir).to receive(:shared_root).and_return(shared) }
    after { FileUtils.rm_rf(scratch) }

    def copy(channel)
      dir = Dir.mktmpdir("main", scratch)
      File.write(File.join(dir, "rust-toolchain.toml"), "[toolchain]\nchannel = \"#{channel}\"\n")
      FileUtils.mkdir_p(File.join(dir, "rust", "host"))
      File.write(File.join(dir, "rust", "host", "Cargo.toml"), "[package]\n")
      dir
    end

    def linked(dir) = File.realpath(File.join(dir, "rust", "host", "target"))

    it "links a crate's target of two successive copies to the same directory" do
      first = copy("1.98.0").tap { |dir| target.link(dir) }
      expect(linked(copy("1.98.0").tap { |dir| target.link(dir) })).to eq(linked(first))
    end

    it "links a copy of another toolchain to another directory" do
      first = copy("1.98.0").tap { |dir| target.link(dir) }
      expect(linked(copy("1.99.0").tap { |dir| target.link(dir) })).not_to eq(linked(first))
    end

    it "keeps the output out of the copy and out of the owner's checkout", :aggregate_failures do
      dir = copy("1.98.0").tap { |each| target.link(each) }
      expect(linked(dir)).to start_with(File.realpath(shared))
      expect(linked(dir)).not_to start_with(Hecks::RustBuild::ROOT)
    end

    it "lays each directory out as a target the Rust prune reaches and takes for no slot", :aggregate_failures do
      deps = File.join(target.link(copy("1.98.0")).first, "debug", "deps", "libold.rlib")
      FileUtils.mkdir_p(File.dirname(deps)) && File.write(deps, "old") && File.utime(Time.at(0), Time.at(0), deps)
      expect(Hecks::RustBuild::Prune.stale(Hecks::RustBuild::Prune.shared_targets(shared), days: 1, dry_run: true)).to be_positive
      expect(Hecks::RustBuild::Prune.unlisted_slots(shared, [], dry_run: true, now: Time.now + (10 * 86_400))).to eq(0)
    end
  end

  # The turn a verification takes at its checkout's copy directory.
  describe "the turn at the copy" do
    let(:lock) { Hecks::Adapters::MainIntegration::CopyLock }
    let(:dir) { Dir.mktmpdir("copy-lock-spec") }
    let(:file) { File.join(dir, "hecks-main-integration.lock") }

    after { FileUtils.rm_rf(dir) }

    def second_turn = -> { lock.hold(file, wait: 0) { nil } }

    it "refuses a second verification past the wait, naming the holder" do
      lock.hold(file, wait: 60) do
        expect(second_turn).to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /pid #{Process.pid} since/)
      end
    end

    def repository
      system("git", "init", "--quiet", dir) && File.write(File.join(dir, "README"), "copy\n")
      system("git", "-C", dir, "-c", "user.name=spec", "-c", "user.email=spec@example.com", "commit", "--quiet",
             "--allow-empty", "-m", "first")
      Hecks::Adapters::MainIntegration::Repository.new(dir)
    end

    it "makes each copy of a checkout at one path and leaves nothing behind", :aggregate_failures do
      repo = repository
      paths = Array.new(2) { repo.clean_copy("HEAD") { |copy| copy } }
      expect(paths.uniq).to eq([File.join(repo.scratch, "main")])
      expect(File.exist?(repo.scratch)).to be(false)
    end
  end
end

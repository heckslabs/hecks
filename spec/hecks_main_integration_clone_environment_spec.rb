require "spec_helper"
require "json"
require "rbconfig"
require "hecks/rust_build"
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
end

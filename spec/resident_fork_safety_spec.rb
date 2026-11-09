require "spec_helper"
require "open3"
require "rbconfig"
require "hecks/adapters/driving/resident/spawn_env"
require "hecks/adapters/driving/resident/env_trace"
require "hecks/adapters/driving/resident/fork_warmup"
require "hecks/adapters/driving/resident/crowd"
require "hecks/adapters/driving/resident/loading"

# A resident forks a child per line and the child never execs. On macOS the `pg` gem's libpq sets up
# a Kerberos system class on its first connection attempt, and the Objective-C runtime aborts a
# process that does that between fork and exec: the crash reports of resident children all read
# "crashed on child side of fork pre-exec". The resident is started with
# OBJC_DISABLE_INITIALIZE_FORK_SAFETY and makes one refused connection before it forks.
RSpec.describe "a resident child opening a Postgres connection" do
  # The crash exists only where libpq reaches the Kerberos framework: macOS with the `pg` gem. The
  # two examples that fork real children run there and are left out elsewhere, not skipped.
  MAC_WITH_PG = RUBY_PLATFORM.include?("darwin") && Gem::Specification.find_all_by_name("pg").any?

  let(:spawn_env) { Hecks::Adapters::Driving::Resident::SpawnEnv }
  let(:warmup) { Hecks::Adapters::Driving::Resident::ForkWarmup }
  let(:variable) { "OBJC_DISABLE_INITIALIZE_FORK_SAFETY" }

  # Forks three children from a Ruby that has `pg` loaded; each opens one refused connection and
  # exits. Prints whether each ended cleanly or by a signal. `--warm` makes the parent open one
  # refused connection first.
  let(:forking) do
    <<~RUBY
      require "pg"
      probe = -> { PG::Connection.connect_start("host=127.0.0.1 port=1 connect_timeout=1").finish }
      probe.call if ARGV.include?("--warm")
      ended = Array.new(3) do
        pid = fork { begin; probe.call; rescue StandardError; nil; end; exit!(0) }
        Process.wait(pid)
        $?.signaled? ? "signal" : "ok"
      end
      puts ended.join(",")
    RUBY
  end

  def children(env, *args)
    root = File.expand_path("..", __dir__)
    plain = { "BUNDLE_GEMFILE" => File.join(root, "Gemfile"), "PGGSSENCMODE" => nil }
    out, = Open3.capture3(plain.merge(env), RbConfig.ruby,
                          "-rbundler/setup", "-e", forking, "--", *args, chdir: root)
    out.strip
  end

  it "starts every resident with the fork-safety switch, whatever its starter had" do
    expect(spawn_env.build({ "PATH" => "/bin" })).to include(variable => "YES")
  end

  it "replaces a starter's own value for it" do
    expect(spawn_env.build({ variable => "NO" })).to include(variable => "YES")
  end

  it "still drops the starter's other variables" do
    expect(spawn_env.build({ "HECKS_CALLER" => "x", "PGHOST" => "h" }))
      .to eq(variable => "YES", "PGGSSENCMODE" => "disable")
  end

  it "does not make the switch part of what a line is compared on", :aggregate_failures do
    expect(Hecks::Adapters::Driving::Resident::EnvTrace::KEPT).not_to match(variable)
    expect(Hecks::Adapters::Driving::Resident::Loading::LOADED_WITH).not_to include(variable)
  end

  it "makes one refused connection on macOS before the resident forks", :aggregate_failures do
    opened = []

    expect(warmup.run(platform: "arm64-darwin24", probe: -> { opened << :probe })).to be(true)
    expect(opened).to eq([:probe])
  end

  it "does nothing on another platform" do
    expect(warmup.run(platform: "x86_64-linux", probe: -> { raise "must not run" })).to be(false)
  end

  it "survives a missing gem or a failing probe", :aggregate_failures do
    expect(warmup.run(platform: "darwin", probe: -> { raise LoadError, "no pg" })).to be(false)
    expect(warmup.run(platform: "darwin", probe: -> { raise "refused" })).to be(false)
  end

  it "ends cleanly in forked children when the switch is set", :aggregate_failures, if: MAC_WITH_PG do
    expect(children(variable => "YES")).to eq("ok,ok,ok")
  end

  it "ends cleanly in forked children when the parent opened one connection first", if: MAC_WITH_PG do
    expect(children({ variable => nil }, "--warm")).to eq("ok,ok,ok")
  end
end

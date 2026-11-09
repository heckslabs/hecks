require "spec_helper"
require "tmpdir"
require "hecks/adapters/driving/resident/server"
require "hecks/adapters/driving/resident/client"
require "hecks/adapters/driving/resident/spawn_env"

# A resident is started with one plain environment, whoever starts it, and says which variables a
# refused line differed on (ADR 0201). A resident that was not born plain (an older one) and
# keeps refusing callers is replaced. No process starts: the system's process table and signals
# are stood in for.
RSpec.describe "a resident's environment" do
  let(:resident) { Hecks::Adapters::Driving::Resident }
  let(:paths) { resident::Paths }

  around do |example|
    Dir.mktmpdir("hrce") do |dir|
      saved = ENV.to_h.slice("HECKS_CACHE_DIR")
      ENV["HECKS_CACHE_DIR"] = dir
      FileUtils.mkdir_p(paths.directory, mode: 0o700)
      example.run
    ensure
      ENV.update(saved)
    end
  end

  def root = "/checkout"

  describe "the environment it is started with" do
    let(:caller_env) do
      { "PATH" => "/bin", "HOME" => "/h", "TMPDIR" => "/t", "LC_ALL" => "C", "XDG_CACHE_HOME" => "/c",
        "HECKS_CACHE_DIR" => "/hc", "HECKS_FOO" => "1", "HECKS_ENVIRONMENT" => "memory", "BUNDLE_GEMFILE" => "/g",
        "RUBYOPT" => "-rbundler/setup", "RUBYLIB" => "/l", "GEM_HOME" => "/gh", "CARGO_TARGET_DIR" => "/ct",
        "PGHOST" => "db", "CLAUDE_CODE_SESSION_ID" => "s", "SSH_AUTH_SOCK" => "/s" }
    end

    it "keeps where its programs and cache are, who it is and its locale, and adds the fork switch",
       :aggregate_failures do
      built = resident::SpawnEnv.build(caller_env)
      expect(built.keys).to contain_exactly("PATH", "HOME", "TMPDIR", "LC_ALL", "XDG_CACHE_HOME", "HECKS_CACHE_DIR",
                                            "OBJC_DISABLE_INITIALIZE_FORK_SAFETY")
      expect(built["HOME"]).to eq("/h")
    end

    it "keeps the protocol a spec names for the resident's own files" do
      built = resident::SpawnEnv.build(caller_env.merge("HECKS_RESIDENT_PROTOCOL" => "1"))
      expect(built["HECKS_RESIDENT_PROTOCOL"]).to eq("1")
    end

    it "drops the HECKS, CARGO, PG, Bundler, Ruby and session variables, and the rest" do
      dropped = %w[HECKS_FOO HECKS_ENVIRONMENT BUNDLE_GEMFILE RUBYOPT RUBYLIB GEM_HOME CARGO_TARGET_DIR PGHOST
                   CLAUDE_CODE_SESSION_ID SSH_AUTH_SOCK]
      expect(resident::SpawnEnv.build(caller_env).keys & dropped).to be_empty
    end

    it "is the same whoever starts it, whatever else they carry" do
      other = caller_env.merge("HECKS_BAR" => "2", "GEM_PATH" => "/gp")
      expect(resident::SpawnEnv.build(other)).to eq(resident::SpawnEnv.build(caller_env))
    end

    it "is what a launcher starts the resident with, and nothing else is inherited", :aggregate_failures do
      allow(Process).to receive(:spawn).and_return(1)
      allow(Process).to receive(:detach)
      resident::Client.spawn_resident("/c", File.expand_path("../exe/hecks", __dir__))
      expect(Process).to have_received(:spawn).with(resident::SpawnEnv.build, anything, "-I", anything, anything,
                                                    "/c", anything, hash_including(unsetenv_others: true))
    end
  end

  describe "what the resident was born under" do
    it "is plain when it holds only the cache variables", :aggregate_failures do
      names = resident::Baseline.odd({ "HOME" => "/h", "XDG_CACHE_HOME" => "/c", "HECKS_CACHE_DIR" => "/hc" })
      resident::Baseline.write(root, names)
      expect(names).to be_empty
      expect(resident::Baseline.atypical?(root)).to be(false)
    end

    it "is not plain when it holds more, and the file names the variables", :aggregate_failures do
      names = resident::Baseline.odd({ "HOME" => "/h", "BUNDLE_GEMFILE" => "/g", "RUBYOPT" => "-r" })
      resident::Baseline.write(root, names)
      expect(resident::Baseline.atypical?(root)).to be(true)
      expect(File.read(paths.baseline(root))).to eq("BUNDLE_GEMFILE RUBYOPT")
    end

    it "is not plain when the resident never said, as an older resident never did" do
      expect(resident::Baseline.atypical?(root)).to be(true)
    end
  end

  describe "the variables a refused line differs on" do
    let(:server) { resident::Server.new("/checkout", "/checkout/exe/hecks") }
    let(:loaded) { { "HECKS_ENGINE" => "ruby" } }

    before do
      allow(resident::EnvTrace).to receive(:names).and_return(%w[HECKS_QUIESCE_STATE HECKS_RUST_DIR HECKS_MINT_STATE])
      server.instance_variable_set(:@environment, loaded)
      server.instance_variable_set(:@fingerprint, instance_double(resident::Fingerprint, changed?: false))
    end

    def line(env) = { script: "/checkout/exe/hecks", env: env }

    it "names the first differing variable, never its value", :aggregate_failures do
      reason = server.send(:unservable, line({ "HECKS_ENGINE" => "kernel" }))
      expect(reason).to eq("env:HECKS_ENGINE")
      expect(reason).not_to include("kernel")
    end

    it "names at most three, joined with a plus" do
      env = { "HECKS_ENGINE" => "k", "HECKS_QUIESCE_STATE" => "q", "HECKS_RUST_DIR" => "r", "HECKS_MINT_STATE" => "m" }
      expect(server.send(:unservable, line(env))).to eq("env:HECKS_ENGINE+HECKS_QUIESCE_STATE+HECKS_RUST_DIR")
    end

    it "does not refuse a line that has the resident's own values" do
      expect(server.send(:unservable, line({ "HECKS_ENGINE" => "ruby" }))).to be_nil
    end

    it "says it in a reply that fits one line of the wire", :aggregate_failures do
      allow(resident::EnvTrace).to receive(:names).and_return(%w[HECKS_STOREHOUSE_ROOT HECKS_QUIESCE_STALE_SECONDS])
      reason = server.send(:unservable, line({ "HECKS_STOREHOUSE_ROOT" => "a", "HECKS_QUIESCE_STALE_SECONDS" => "b",
                                               "HECKS_ENGINE" => "c" }))
      expect(reason.bytesize).to be <= resident::Serving::NAMES_WIDTH + "env:".bytesize
      expect("stale:#{reason}".bytesize).to be <= resident::Wire::MAX_LINE
    end

    it "reaches the usage log as the refusal the launcher notes" do
      expect(resident::Outcome.refused(resident::Client.refusal("stale:env:HECKS_ENGINE"))).to eq("refused:env:HECKS_ENGINE")
    end
  end

  describe "the library path a Ruby version manager adds" do
    let(:server) { resident::Server.new("/checkout", "/checkout/exe/hecks") }
    let(:hook) { "/opt/homebrew/Cellar/rbenv/1.3.2/rbenv.d/exec/gem-rehash:" }

    before do
      server.instance_variable_set(:@environment, {})
      server.instance_variable_set(:@fingerprint, instance_double(resident::Fingerprint, changed?: false))
    end

    def line(env) = { script: "/checkout/exe/hecks", env: env }

    it "is no difference between a launcher that carries it and a resident that does not" do
      expect(server.send(:unservable, line({ "RUBYLIB" => hook }))).to be_nil
    end

    it "is a difference once the caller adds a path of its own, named by the variable", :aggregate_failures do
      expect(server.send(:unservable, line({ "RUBYLIB" => "/my/lib:#{hook}" }))).to eq("env:RUBYLIB")
      expect(resident::EnvValue.of("RUBYLIB", "/my/lib:#{hook}")).to eq("/my/lib")
    end

    it "leaves every other variable as it is", :aggregate_failures do
      expect(resident::EnvValue.of("RUBYOPT", hook)).to eq(hook)
      expect(resident::EnvValue.of("RUBYLIB", nil)).to be_nil
      expect(resident::EnvValue.of("RUBYLIB", "")).to be_nil
    end

    it "does not make a resident born with only that entry odd", :aggregate_failures do
      expect(resident::Baseline.odd({ "HOME" => "/h", "RUBYLIB" => hook })).to be_empty
      expect(resident::Baseline.odd({ "RUBYLIB" => "/my/lib" })).to eq(["RUBYLIB"])
    end
  end

  describe "a resident that was not born plain and keeps refusing" do
    let(:stop) { instance_double(Proc, call: true) }
    let(:look) { ->(_pid) { [Process.uid, "ruby #{resident::Stuck::SERVER} #{root}"] } }

    before { File.write(paths.pid(root), "4242") }

    def refused(times, why = "env:HECKS_ENGINE")
      Array.new(times) { resident::Stuck.after(root, why, look: look, stop: stop) }
    end

    it "is stopped at the third refusal, and not before", :aggregate_failures do
      expect(refused(2)).to eq([false, false])
      expect(refused(1)).to eq([true])
      expect(stop).to have_received(:call).with(4242)
    end

    it "is left alone when it was born plain, however often it refuses", :aggregate_failures do
      resident::Baseline.write(root, [])
      expect(refused(5)).to all(be(false))
      expect(stop).not_to have_received(:call)
    end

    it "forgets the refusals when the resident serves or refuses for another reason", :aggregate_failures do
      refused(2)
      resident::Stuck.after(root, nil, look: look, stop: stop)
      expect(refused(2)).to eq([false, false])
      expect(stop).not_to have_received(:call)
    end

    it "counts only refusals within the minute" do
      refused(2)
      File.write(paths.envs(root), [Time.now.to_f - 120, Time.now.to_f - 90].join("\n"))
      expect(refused(1)).to eq([false])
    end

    it "stops only this user's resident for this checkout", :aggregate_failures do
      stranger = ->(_pid) { [Process.uid + 1, "ruby #{resident::Stuck::SERVER} #{root}"] }
      expect(Array.new(3) { resident::Stuck.after(root, "env:X", look: stranger, stop: stop) }).to all(be(false))
      expect(stop).not_to have_received(:call)
    end
  end
end

require "spec_helper"
require "tmpdir"
require "hecks/adapters/driving/resident/server"
require "hecks/adapters/driving/resident/client"

# What a launcher and a resident trust, and what they refuse to start (ADR 0201): directories and
# sockets that are this user's own and closed to others, a cache directory that a later launcher
# finds again, a cap on residents checked before anything loads, the variables the loaded code
# read, the files whose change retires a resident, and the long-running servers a launcher keeps
# for itself.
RSpec.describe "what the resident trusts" do
  let(:resident) { Hecks::Adapters::Driving::Resident }
  let(:paths) { resident::Paths }

  around do |example|
    Dir.mktmpdir("hrt") do |dir|
      @dir = dir
      saved = ENV.fetch("HECKS_CACHE_DIR", nil)
      ENV["HECKS_CACHE_DIR"] = dir
      example.run
    ensure
      ENV["HECKS_CACHE_DIR"] = saved
    end
  end

  describe "the directories and the socket" do
    it "trusts a directory that is this user's and closed to others, and one that is not there yet", :aggregate_failures do
      expect(paths.trusted_directory?(@dir)).to be(true)
      expect(paths.trusted_directory?(File.join(@dir, "later"))).to be(true)
    end

    it "does not trust a directory others can write to" do
      File.chmod(0o777, @dir)
      expect(paths.trusted_directory?(@dir)).to be(false)
    end

    it "does not use a resident whose cache directory others can write to" do
      File.chmod(0o777, @dir)
      expect(paths.usable?("/c")).to be(false)
    end

    # Binds the checkout's socket with the given mode and closes the listener, leaving the file.
    def socket_with(mode)
      FileUtils.mkdir_p(paths.directory)
      UNIXServer.new(paths.socket("/c")).close
      File.chmod(mode, paths.socket("/c"))
    end

    it "does not trust a socket path that is a plain file" do
      FileUtils.mkdir_p(paths.directory)
      FileUtils.touch(paths.socket("/c"))
      expect(paths.trusted_socket?("/c")).to be(false)
    end

    it "does not trust a socket others can write to" do
      socket_with(0o666)
      expect(paths.trusted_socket?("/c")).to be(false)
    end

    it "trusts a socket that is this user's own" do
      socket_with(0o600)
      expect(paths.trusted_socket?("/c")).to be(true)
    end
  end

  describe "a cache directory that is new each time" do
    before do
      ENV["HECKS_CACHE_DIR"] = nil
      allow(Hecks::CacheDir).to receive(:stable?).and_return(false)
    end

    it "is not one a resident may use, since no later launcher would find it" do
      expect(paths.usable?("/c")).to be(false)
    end

    it "is fine once the cache directory is named" do
      ENV["HECKS_CACHE_DIR"] = @dir
      expect(paths.persistent?).to be(true)
    end
  end

  describe "the cap on residents" do
    after { @held&.close }

    def holding(root)
      FileUtils.mkdir_p(paths.directory)
      lock = File.new(paths.lock(root), File::CREAT | File::RDWR)
      lock.flock(File::LOCK_EX)
      lock
    end

    # Whether two other residents fill a cap of `cap`.
    def crowded_at?(cap)
      held = [holding("/a"), holding("/b")]
      resident::Crowd.remember(cap)
      resident::Crowd.crowded?("/c")
    ensure
      held&.each(&:close)
    end

    it "is crowded when the others that hold a lock fill the cap the world last declared" do
      expect(crowded_at?(2)).to be(true)
    end

    it "is not crowded while the cap is above the others that hold a lock" do
      expect(crowded_at?(3)).to be(false)
    end

    it "uses the default cap until a resident has written another" do
      expect(resident::Crowd.cap).to eq(8)
    end

    it "writes the cap through a rename, leaving no temp file", :aggregate_failures do
      FileUtils.mkdir_p(paths.directory)
      resident::Crowd.remember(5)

      expect(resident::Crowd.cap).to eq(5)
      expect(Dir.children(paths.directory)).to eq(["cap"])
    end

    # A lock file last used `age` seconds ago, with files of the same stem beside it.
    def lock_file(name, age, beside: [])
      FileUtils.mkdir_p(paths.directory)
      stem = File.join(paths.directory, name)
      (["lock"] + beside).each { |ext| File.write("#{stem}.#{ext}", "") }
      File.utime(Time.now - age, Time.now - age, "#{stem}.lock")
      "#{stem}.lock"
    end

    # A lock file three days old that a live resident holds.
    def held_lock(name) = File.new(lock_file(name, 3 * 86_400), File::RDWR).tap { |lock| lock.flock(File::LOCK_EX) }

    it "removes the lock files of residents that are gone for a day" do
      gone = lock_file("aaaaaaaa", 3 * 86_400)
      resident::Crowd.sweep

      expect(File.exist?(gone)).to be(false)
    end

    it "leaves a recent lock file, and one with a socket beside it" do
      kept = [lock_file("bbbbbbbb", 3600), lock_file("cccccccc", 3 * 86_400, beside: ["sock"])]
      resident::Crowd.sweep

      expect(kept.all? { |file| File.exist?(file) }).to be(true)
    end

    it "leaves a lock file that a resident holds, however old" do
      @held = held_lock("dddddddd")
      resident::Crowd.sweep

      expect(File.exist?(@held.path)).to be(true)
    end

    it "sweeps the locks of gone residents when a resident takes its own" do
      gone = lock_file("eeeeeeee", 3 * 86_400)
      server = resident::Server.new("/c", "/c/exe/hecks")
      server.send(:lock_taken?)

      expect(File.exist?(gone)).to be(false)
    end

    it "keeps a launcher from starting a resident when the cap is met" do
      allow(resident::Crowd).to receive(:crowded?).and_return(true)
      allow(Process).to receive(:spawn)
      resident::Client.spawn_resident("/c", File.expand_path("../exe/hecks", __dir__))
      expect(Process).not_to have_received(:spawn)
    end

    def crowded_server
      FileUtils.mkdir_p(paths.directory)
      allow(resident::Crowd).to receive(:crowded?).and_return(true)
      resident::Server.new("/c", "/c/exe/hecks").tap { |server| allow(server).to receive(:prepare) }
    end

    it "ends a resident that finds the cap met before it loads anything" do
      server = crowded_server
      server.run
      expect(server).not_to have_received(:prepare)
    end
  end

  describe "the variables the loaded code read" do
    let(:server) { resident::Server.new("/checkout", "/checkout/exe/hecks") }
    let(:request) { { script: "/checkout/exe/hecks", env: { "HECKS_QUIESCE_STATE" => "/tmp/other" } } }

    before do
      resident::EnvTrace.tracing { ENV.fetch("HECKS_QUIESCE_STATE", nil) }
      server.instance_variable_set(:@fingerprint, instance_double(resident::Fingerprint, changed?: false))
      server.instance_variable_set(:@environment, { "HECKS_QUIESCE_STATE" => "/home/x/quiesce" })
    end

    it "notes a HECKS, CARGO or PG variable read while tracing, and nothing read outside it", :aggregate_failures do
      resident::EnvTrace.tracing { %w[CARGO_TARGET_DIR PGHOST PATH].each { |name| ENV.key?(name) } }
      ENV.key?("HECKS_NOT_READ_WHILE_TRACING")
      expect(resident::EnvTrace.names).to include("HECKS_QUIESCE_STATE", "CARGO_TARGET_DIR", "PGHOST")
      expect(resident::EnvTrace.names).not_to include("PATH", "HECKS_NOT_READ_WHILE_TRACING")
    end

    it "does not serve a line made with another value of a variable the code read when it loaded" do
      expect(server.send(:servable?, request)).to be(false)
    end

    it "does not serve a line that has the variable when the resident loaded without it" do
      server.instance_variable_set(:@environment, {})
      expect(server.send(:servable?, request)).to be(false)
    end

    it "serves a line made with the same value" do
      same = request.merge(env: { "HECKS_QUIESCE_STATE" => "/home/x/quiesce" })
      expect(server.send(:servable?, same)).to be(true)
    end

    it "serves a line that differs only on a variable the code did not read at load", :aggregate_failures do
      other = request.merge(env: { "HECKS_QUIESCE_STATE" => "/home/x/quiesce", "HECKS_CALLER" => "a session" })
      expect(server.send(:servable?, other)).to be(true)
    end

    it "does not serve a line from another launcher script" do
      expect(server.send(:servable?, request.merge(script: "/elsewhere/exe/hecks"))).to be(false)
    end
  end

  describe "the fingerprint" do
    around do |example|
      Dir.mktmpdir("hrf") do |root|
        @root = root
        FileUtils.mkdir_p([File.join(root, "lib/hecks"), File.join(root, "exe"), File.join(root, "qa")])
        File.write(File.join(root, "lib/hecks/a.rb"), "A = 1\n")
        File.write(File.join(root, "exe/hecks"), "#!/usr/bin/env ruby\n")
        example.run
      end
    end

    let(:fingerprint) { resident::Fingerprint.new(@root).tap(&:mark!) }

    it "does not retire for a domain directory it was told to watch after it was built", :aggregate_failures do
      File.write(File.join(@root, "qa/x.bluebook"), "")
      fingerprint.watch(File.join(@root, "qa"))
      expect(fingerprint.changed?).to be(false)
    end

    it "retires for a change to a file of a watched directory made later" do
      fingerprint.watch(File.join(@root, "qa"))
      File.write(File.join(@root, "qa/x.bluebook"), "")
      expect(fingerprint.changed?).to be(true)
    end

    it "retires when a world, hecksagon or bluebook file appears at the checkout's root" do
      fingerprint
      File.write(File.join(@root, "x.world"), "")
      expect(fingerprint.changed?).to be(true)
    end

    it "retires when the launcher itself changes" do
      fingerprint
      File.write(File.join(@root, "exe/hecks"), "#!/usr/bin/env ruby\n# changed\n")
      expect(fingerprint.changed?).to be(true)
    end

    it "retires when the Ruby version file appears" do
      fingerprint
      File.write(File.join(@root, ".ruby-version"), "3.3.7\n")
      expect(fingerprint.changed?).to be(true)
    end

    it "retires when a hidden file under lib changes" do
      fingerprint
      File.write(File.join(@root, "lib/hecks/.hidden"), "x")
      expect(fingerprint.changed?).to be(true)
    end
  end

  describe "a line made under another HECKS_ENVIRONMENT, through the real load" do
    let(:root) { File.expand_path("..", __dir__) }
    let(:script) { File.join(root, "exe/hecks") }
    let(:server) { resident::Server.new(root, script) }

    # A line made with the process's own environment, plus the given variables.
    def request(plus = {}, without = [])
      { script: script, argv: [], cwd: root, env: ENV.to_h.except(*without).merge(plus) }
    end

    # Loads the Hecks domain the way a resident starts: the code is already in this process.
    def loaded
      resident::EnvTrace.send(:instance_variable_get, :@names).clear
      allow(server).to receive(:require_hecks)
      server.send(:prepare)
    end

    it "is seen to read HECKS_ENVIRONMENT while loading, and still serves lines with and without it", :aggregate_failures do
      loaded
      expect(resident::EnvTrace.names).to include("HECKS_ENVIRONMENT")
      expect(server.send(:loaded_names)).not_to include("HECKS_ENVIRONMENT")
      expect(server.send(:servable?, request({ "HECKS_ENVIRONMENT" => "memory" }))).to be(true)
      expect(server.send(:servable?, request({}, ["HECKS_ENVIRONMENT"]))).to be(true)
    end

    it "still refuses a line that differs on a variable the code read that is not the environment" do
      loaded
      resident::EnvTrace.tracing { ENV.fetch("HECKS_QUIESCE_STATE", nil) }
      server.send(:note_environment)
      expect(server.send(:servable?, request({ "HECKS_QUIESCE_STATE" => "/elsewhere" }))).to be(false)
    end

    it "matches a line on GEM_HOME and GEM_PATH, which pick the gems it runs with", :aggregate_failures do
      expect(resident::Loading::LOADED_WITH).to include("GEM_HOME", "GEM_PATH")
      expect(resident::Loading::PER_LINE).to eq(["HECKS_ENVIRONMENT"])
    end
  end

  describe "the long-running servers" do
    def bypassed?(*argv)
      saved = ARGV.dup
      ARGV.replace(argv)
      resident::Client.bypass?
    ensure
      ARGV.replace(saved)
    end

    around do |example|
      saved = ENV.fetch("HECKS_NO_RESIDENT", nil)
      ENV.delete("HECKS_NO_RESIDENT")
      example.run
    ensure
      ENV["HECKS_NO_RESIDENT"] = saved
    end

    it "are run by the launcher itself, however the verb is spelled", :aggregate_failures do
      spellings = [%w[pipeline_board PipelineBoard.serve!], %w[PipelineBoard.serve!], %w[pipeline_board.serve!],
                   %w[Hecks::PipelineBoard.serve!], %w[Server.present!], %w[server.compose!], %w[Server.preview!]]
      expect(spellings.map { |argv| bypassed?(*argv) }).to all(be(true))
    end

    it "include the server that answers MCP over stdio" do
      expect(bypassed?("Server.serve_query_ir_mcp!")).to be(true)
    end

    it "leave ordinary lines, even ones that name a preview, to the resident", :aggregate_failures do
      expect(bypassed?("Dispatch.Preview", "repo.value=.")).to be(false)
      expect(bypassed?("RedFlag.status")).to be(false)
    end
  end
end

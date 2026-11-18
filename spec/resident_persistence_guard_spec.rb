require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/adapters/driving/resident/server"
require "hecks/adapters/driving/resident/atypical"
require "hecks/adapters/driving/resident/client"

# A resident that resolved an aggregate to Memory which the checkout's local hecksagon binds to
# SQLite answers success and writes nothing the ledger holds; it refuses by name instead.
RSpec.describe Hecks::Adapters::Driving::Resident::PersistenceGuard do
  let(:guard) { described_class }
  let(:bind) { %(Hecks.hecksagon "Tickets" do\n  Tickets::Work.persisted_by("SqlitePersistence")\nend\n) }

  def domain_with(text)
    Dir.mktmpdir("hrpg") do |dir|
      File.write(File.join(dir, "hecks.local.hecksagon"), text) if text
      yield dir
    end
  end

  def rows(store) = [["store Tickets", "Memory", "default"], ["store Tickets::Work", store, "aggregate bind"]]

  describe "what the local hecksagons declare" do
    it "names the aggregates bound to SQLite" do
      domain_with(bind) { |dir| expect(guard.declared(dir, {})).to eq(["Tickets::Work"]) }
    end

    it "names none when the checkout keeps no local hecksagon" do
      domain_with(nil) { |dir| expect(guard.declared(dir, {})).to eq([]) }
    end
  end

  describe "comparing them with what the registry resolved" do
    it "finds an aggregate declared on SQLite that loaded on Memory" do
      expect(guard.gap(["Tickets::Work"], rows("Memory"))).to eq("Tickets::Work")
    end

    it "finds none when the aggregate loaded on SQLite" do
      expect(guard.gap(["Tickets::Work"], rows("SqliteAt /x.db"))).to be_nil
    end

    it "finds none for an aggregate on Memory that nothing declares on SQLite" do
      expect(guard.gap([], rows("Memory"))).to be_nil
    end

    it "finds a declared aggregate the registry wrote no row for, beside one it keeps in SQLite" do
      expect(guard.gap(%w[Tickets::Work Tickets::Epic], rows("SqliteAt /x.db"))).to eq("Tickets::Epic")
    end

    it "finds none when the aggregate has no row of its own and its bluebook is kept in SQLite" do
      expect(guard.gap(["Tickets::Epic"], [["store Tickets", "SqliteAt /x.db", "hecksagon"]])).to be_nil
    end

    it "finds an aggregate the registry keeps in another database than the SQLite declared" do
      expect(guard.gap(["Tickets::Work"], rows("Postgres hecks"))).to eq("Tickets::Work")
    end
  end

  describe "the environment a line is served from" do
    it "keys an unset or empty environment as none, and keeps a named one", :aggregate_failures do
      expect(guard.environment(nil)).to be_nil
      expect(guard.environment("")).to be_nil
      expect(guard.environment("local")).to eq("local")
    end

    it "names an unreadable registry by its error's class, so the refusal stays one line" do
      expect(guard.unreadable(Hecks::Runtime::WiringError.new("x"))).to eq("persistence:unreadable:WiringError")
    end
  end

  describe "the lines meant to run on Memory" do
    it "exempts the spec switch and the memory and test environments", :aggregate_failures do
      expect(guard.exempt?("HECKS_WRITES_LOCAL" => "1")).to be(true)
      expect(guard.exempt?("HECKS_ENVIRONMENT" => "memory")).to be(true)
      expect(guard.exempt?("HECKS_ENVIRONMENT" => "test")).to be(true)
    end

    it "does not exempt a plain line" do
      expect(guard.exempt?({})).to be(false)
    end
  end

  describe "a resident that holds such a gap" do
    let(:server) { Hecks::Adapters::Driving::Resident::Server.new("/checkout", "/checkout/exe/hecks") }

    before do
      server.instance_variable_set(:@persistence_refusals, { nil => "persistence:Tickets::Work" })
      allow(server).to receive(:retire)
    end

    it "refuses a plain line by the aggregate's name and retires", :aggregate_failures do
      expect(server.send(:unpersisted, {})).to eq("persistence:Tickets::Work")
      expect(server).to have_received(:retire).once
    end

    it "serves a line that asks for Memory, and does not retire", :aggregate_failures do
      expect(server.send(:unpersisted, "HECKS_ENVIRONMENT" => "memory")).to be_nil
      expect(server).not_to have_received(:retire)
    end

    it "is not counted as an environment refusal, so it never replaces itself in a loop" do
      expect(Hecks::Adapters::Driving::Resident::Atypical.env?("persistence:Tickets::Work")).to be(false)
    end
  end

  describe "the launcher that meets the refusal" do
    let(:client) { Hecks::Adapters::Driving::Resident::Client }

    before do
      allow(client).to receive_messages(ask: [nil, "persistence:Tickets::Work"], spawn_resident: "started")
      allow(Hecks::Adapters::Driving::Resident::Stuck).to receive(:after)
    end

    it "boots the line on its own, so it runs on the ledger, and starts a new resident", :aggregate_failures do
      outcome = client.attempt("/checkout", "/checkout/exe/hecks")
      expect(outcome).to eq(Hecks::Adapters::Driving::Resident::Outcome.refused("persistence:Tickets::Work"))
      expect(client).to have_received(:spawn_resident).once
    end
  end

  # The Hecks domain of a checkout, loaded the way a resident loads it after a merge: through its
  # own cache, with the local hecksagon the checkout keeps. `Ledger` stands for Tickets.
  describe "a resident over a loaded domain" do
    let(:server) { Hecks::Adapters::Driving::Resident::Server.new(@root, File.join(@root, "exe/hecks")) }

    # The specs' declaration cache knows a scratch domain by its contents alone and would hand a
    # load the registry an earlier example loaded with other local files, so it is off here.
    around do |example|
      held = ENV.fetch("HECKS_NO_DECLARATION_CACHE", nil)
      ENV["HECKS_NO_DECLARATION_CACHE"] = "1"
      Dir.mktmpdir("hrpg-root") do |root|
        @root = root
        example.run
      end
    ensure
      ENV["HECKS_NO_DECLARATION_CACHE"] = held
    end

    before { allow(server).to receive(:retire) }

    def aggregate(name)
      %(  aggregate "#{name}" do\n    identified_by :name\n    attribute :name, #{name}Name\n) +
        %(    value_object "#{name}Name" do\n      attribute :value, String\n    end\n) +
        %(    command "Open#{name}" do\n      attribute :name, #{name}Name\n      sets :name\n) +
        %(      emits "#{name}Opened"\n    end\n  end\n)
    end

    def local_binds(names)
      lines = names.map { |name| %(  Ledger::#{name}.persisted_by("SqlitePersistence")\n) }
      File.write(File.join(domain, "ledger.local.hecksagon"), %(Hecks.hecksagon "Ledger" do\n#{lines.join}end\n))
    end

    def domain
      File.join(@root, Hecks::Adapters::Driving::Resident::Loading::DOMAIN).tap { |dir| FileUtils.mkdir_p(dir) }
    end

    # Loads the domain into the resident's cache, then lets the guard read the local files as
    # they stand afterwards, as `prepare` does.
    def loaded(bound:, declared: bound, committed: false)
      bluebook = %(Hecks.bluebook "Ledger" do\n#{aggregate("Work")}#{aggregate("Epic")}end\n)
      File.write(File.join(domain, "ledger.bluebook"), bluebook)
      local_binds(bound)
      server.instance_variable_set(:@cache, cache_of(committed))
      local_binds(declared)
      server.instance_variable_set(:@persistence_declared, guard.declared(domain, {}))
    end

    def cache_of(committed)
      cache = Hecks::Adapters::Driving::Resident::DescribedCache.new
      committed ? Hecks::Adapters::FolderOverlay.committed_only { cache.load(domain, nil) } : cache.load(domain, nil)
      cache
    end

    it "serves a line when the loaded domain keeps every declared aggregate in SQLite", :aggregate_failures do
      loaded(bound: %w[Work Epic])
      expect(server.send(:unpersisted, {})).to be_nil
      expect(server).not_to have_received(:retire)
    end

    it "refuses by the Epic's name when the load bound only Work, and retires", :aggregate_failures do
      loaded(bound: %w[Work], declared: %w[Work Epic])
      expect(server.send(:unpersisted, {})).to eq("persistence:Ledger::Epic")
      expect(server).to have_received(:retire).once
    end

    it "refuses when the load read none of the local files" do
      loaded(bound: %w[Work Epic], committed: true)
      expect(server.send(:unpersisted, {})).to eq("persistence:Ledger::Work")
    end

    it "serves a line for an environment the resident has not loaded, whose child loads it cold" do
      loaded(bound: %w[Work], declared: %w[Work Epic])
      expect(server.send(:unpersisted, "HECKS_ENVIRONMENT" => "staging")).to be_nil
    end

    it "refuses, by the error's class, a loaded domain whose stores cannot be read" do
      loaded(bound: %w[Work Epic])
      allow(guard).to receive(:rows_of).and_raise(Hecks::Runtime::WiringError, "two defaults")
      expect(server.send(:unpersisted, {})).to eq("persistence:unreadable:WiringError")
    end

    # A world that keeps the ledger in the named database, as another project's local world does.
    def ledger_world(dir, database)
      text = %(Hecks.world "Ledger" do\n  persisted_by("SqlitePersistence") do\n    database "#{database}"\n  end\nend\n)
      File.write(File.join(dir, "ledger.local.world"), text)
    end

    # Starts the resident's load from a directory whose local hecksagon keeps Work in Memory.
    def loaded_from_elsewhere(elsewhere)
      loaded(bound: %w[Work Epic])
      ledger_world(domain, File.join(@root, "ledger.db"))
      File.write(File.join(elsewhere, "ledger.local.hecksagon"), %(Hecks.hecksagon "Ledger" do\n  Ledger::Work.persisted_by("Memory")\nend\n))
      quiet_loads
      Dir.chdir(elsewhere) { server.send(:load_everything) }
    end

    # Leaves out what a load does besides loading: requiring Hecks, watching and noting the code.
    def quiet_loads
      allow(server).to receive(:require_hecks)
      server.instance_variable_set(:@fingerprint, instance_double(Hecks::Adapters::Driving::Resident::Fingerprint, watch: nil))
      allow(Hecks::Adapters::Driving::UsageCache).to receive(:code_fingerprint)
    end

    it "loads its domain in its checkout, not in the directory it was started from" do
      Dir.mktmpdir("hrpg-elsewhere") do |elsewhere|
        loaded_from_elsewhere(elsewhere)
        rows = guard.rows_of(server.instance_variable_get(:@cache).fetch(domain, nil).registry).to_h { |row| row.first(2) }
        expect(rows["store Ledger::Work"]).to eq("SqliteAt #{File.join(@root, "ledger.db")}")
      end
    end

    it "refuses an environment's line once the resident has loaded that environment too", :aggregate_failures do
      loaded(bound: %w[Work], declared: %w[Work Epic])
      expect(server.send(:unpersisted, "HECKS_ENVIRONMENT" => "staging")).to be_nil
      local_binds(%w[Work])
      server.instance_variable_get(:@cache).load(domain, "staging")
      expect(server.send(:unpersisted, "HECKS_ENVIRONMENT" => "staging")).to eq("persistence:Ledger::Epic")
    end
  end

  # A launcher run from a directory that keeps local files of its own (another project's
  # `*.local.world` naming its own Tickets database) reads them; the resident loaded its domain in
  # its checkout without them, so it hands that line back to be booted where it stands.
  describe "a line from a directory that keeps local files" do
    def with_dirs
      Dir.mktmpdir("hrpg-cwd") do |base|
        dirs = %w[root other plain].to_h { |name| [name, File.join(base, name)] }
        dirs["domain"] = File.join(dirs["root"], Hecks::Adapters::Driving::Resident::Loading::DOMAIN)
        dirs.each_value { |dir| FileUtils.mkdir_p(dir) }
        %w[other domain].each { |name| File.write(File.join(dirs[name], "x.local.world"), "") }
        yield dirs
      end
    end

    it "refuses a directory that keeps one, and serves a plain one, the root and the domain", :aggregate_failures do
      with_dirs do |dirs|
        expect(guard.foreign_overlay(dirs["other"], dirs["root"])).to eq("overlay:cwd")
        expect(%w[plain root domain].map { |name| guard.foreign_overlay(dirs[name], dirs["root"]) }).to eq([nil] * 3)
      end
    end

    it "refuses, for a worktree's resident, the main checkout's domain directory, which a cold launcher reads" do
      with_dirs do |dirs|
        expect(guard.foreign_overlay(dirs["domain"], dirs["plain"])).to eq("overlay:cwd")
      end
    end

    it "serves a line that names no directory, or one that is gone", :aggregate_failures do
      expect(guard.foreign_overlay("", "/checkout")).to be_nil
      expect(guard.foreign_overlay("/no/such/hrpg", "/checkout")).to be_nil
    end

    def server_at(root)
      Hecks::Adapters::Driving::Resident::Server.new(root, "/s").tap do |server|
        allow(server).to receive_messages(same_script?: true, differing: nil, retire: nil)
      end
    end

    it "is refused by the resident without retiring it", :aggregate_failures do
      with_dirs do |dirs|
        server = server_at(dirs["root"])
        expect(server.send(:unservable, { cwd: dirs["other"], env: {} })).to eq("overlay:cwd")
        expect(server).not_to have_received(:retire)
      end
    end
  end

  describe "a declared file that cannot be read" do
    it "declares nothing, unlike a registry that cannot be read, which refuses" do
      allow(Dir).to receive(:glob).and_raise(Errno::EACCES)
      expect(guard.declared("/checkout/lib/hecks/hecks", {})).to eq([])
    end
  end
end

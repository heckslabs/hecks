require "spec_helper"
require "tmpdir"
require "hecks/adapters/driving/resident/server"
require "hecks/adapters/driving/resident/worker"

# A resident serves the findings its checkout's ledger holds now, or refuses by the aggregate's
# name: a line forked after a finding was written reads it, and a resident whose loaded domain
# keeps `Finding` in Memory while the local hecksagon binds it to SQLite, at its load or once a
# bind is written after it, refuses the line and retires. `Ledger` stands for Tickets; its
# database is a file of the example's own, so no live ledger is reached.
RSpec.describe Hecks::Adapters::Driving::Resident::Server do
  let(:guard) { Hecks::Adapters::Driving::Resident::PersistenceGuard }
  let(:server) { described_class.new(@root, File.join(@root, "exe/hecks")) }

  # The specs' declaration cache knows a scratch domain by its contents alone, so it is off here.
  around do |example|
    held = ENV.fetch("HECKS_NO_DECLARATION_CACHE", nil)
    ENV["HECKS_NO_DECLARATION_CACHE"] = "1"
    Dir.mktmpdir("hrff-root") do |root|
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

  def domain
    File.join(@root, Hecks::Adapters::Driving::Resident::Loading::DOMAIN).tap { |dir| FileUtils.mkdir_p(dir) }
  end

  # Writes the bluebook, the local world that names the example's database, and the local
  # hecksagon that binds the named aggregates to SQLite.
  def checkout(bound)
    bluebook = %(Hecks.bluebook "Ledger" do\n#{aggregate("Finding")}#{aggregate("Work")}end\n)
    File.write(File.join(domain, "ledger.bluebook"), bluebook)
    database = File.join(@root, "ledger.db")
    world = %(Hecks.world "Ledger" do\n  persisted_by("SqlitePersistence") do\n    database "#{database}"\n  end\nend\n)
    File.write(File.join(domain, "ledger.local.world"), world)
    local_binds(bound)
  end

  def local_binds(names)
    lines = names.map { |name| %(  Ledger::#{name}.persisted_by("SqlitePersistence")\n) }
    File.write(File.join(domain, "ledger.local.hecksagon"), %(Hecks.hecksagon "Ledger" do\n#{lines.join}end\n))
  end

  # Loads the domain into the resident's cache in its checkout, as `prepare` does, and reads what
  # the local hecksagons bind once the load has run.
  def started(bound:, declared: bound)
    checkout(bound)
    cache = Hecks::Adapters::Driving::Resident::DescribedCache.new
    Dir.chdir(@root) { cache.load(domain, nil) }
    server.instance_variable_set(:@cache, cache)
    local_binds(declared)
    server.instance_variable_set(:@persistence_declared, guard.declared(domain, {}))
  end

  # Runs the block in a forked process in the checkout and answers what it printed.
  def forked
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      Dir.chdir(@root) { writer.write(yield.to_s) }
      exit!(0)
    end
    writer.close
    Process.wait(pid)
    reader.read.tap { reader.close }
  end

  # Opens a finding from a process that loads the domain cold, as a launcher with no resident does.
  def written_cold(name)
    forked { Hecks.boot(domain).dispatch("Ledger::Finding.OpenFinding", with: { name: { value: name } }) && "opened" }
  end

  # Installs, in a forked child, the describing a resident's line uses: the line runs under no
  # environment, as the domain was loaded, so it is answered from the resident's cache.
  def describing_from(cache)
    ENV.delete("HECKS_ENVIRONMENT")
    describing = Hecks::Adapters::Driving::Resident::Worker::Describing
    describing.cache = cache
    describing.notes = StringIO.new
    Hecks.singleton_class.prepend(describing)
  end

  # Opens the finding again in a child of the resident, which describes the domain from what
  # the resident loaded ({Worker::Describing}): a refusal that it already exists means the
  # child read it.
  def seen_by_a_line(name)
    cache = server.instance_variable_get(:@cache)
    forked do
      describing_from(cache)
      Hecks.boot_described(Hecks.describe(domain)).dispatch("Ledger::Finding.OpenFinding", with: { name: { value: name } })
      "not there"
    rescue StandardError => e
      e.message
    end
  end

  it "reads a finding written after the resident loaded, in the line it forks", :aggregate_failures do
    started(bound: %w[Finding Work])
    expect(written_cold("late")).to eq("opened")
    expect(seen_by_a_line("late")).to include("already exists")
  end

  it "refuses by Finding's name, and retires, when its load kept Work in SQLite and Finding in Memory",
     :aggregate_failures do
    started(bound: %w[Work], declared: %w[Work Finding])
    expect(server.send(:unpersisted, {})).to eq("persistence:Ledger::Finding")
    expect(server).to have_received(:retire).once
  end

  # Serves one line, then binds Finding in the local hecksagon after the load, as a rewritten
  # overlay does, and answers the next line's refusal.
  def after_a_bind_arrives
    started(bound: %w[Work])
    served = server.send(:unpersisted, {})
    local_binds(%w[Work Finding])
    [served, server.send(:unpersisted, {})]
  end

  it "refuses by Finding's name, and retires, once a bind is written after it loaded", :aggregate_failures do
    expect(after_a_bind_arrives).to eq([nil, "persistence:Ledger::Finding"])
    expect(server).to have_received(:retire).once
  end

  it "serves the next resident, which loads the rewritten files" do
    started(bound: %w[Work Finding])
    expect(server.send(:unpersisted, {})).to be_nil
  end
end

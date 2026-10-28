require "spec_helper"
require_relative "support/rehearsal_shop"
require "fileutils"
require "json"
require "securerandom"
require "tmpdir"

# A rehearsal through the launcher: `hecks rehearsal_run.request` is a run of RehearsalRun. The
# subject is a small Shop domain whose world names a memory copy of its data (`rehearsed_by`), so
# nothing is created, restored or dropped: the eras held and the records stored come from a JSON
# document beside the domain. Each example changes one thing about that copy or that domain and
# reads what the rehearsal concluded.
RSpec.describe "rehearsing a domain's next era" do
  let(:root) { Dir.mktmpdir("hecks-rehearsal-spec") }
  let(:shop) { File.join(root, "shop") }
  let(:rows_path) { File.join(shop, "rehearsal", "rows.json") }

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  before { RehearsalShop.copy_to(shop) }

  after { FileUtils.remove_entry(root) }

  # A rehearsal is five reactions deep. The spec runner is itself a run, so the depth it has
  # already reached is set aside: it is not this run's.
  def launch(*argv)
    outer = Thread.current[:hecks_reaction_depth]
    Thread.current[:hecks_reaction_depth] = 0
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  ensure
    Thread.current[:hecks_reaction_depth] = outer
  end

  # Runs one rehearsal of the shop and answers the record it ended as.
  def rehearse(run = "r-#{SecureRandom.hex(4)}", *args)
    launch("rehearsal_run.request", "run=#{run}", "domain=#{shop}", *args)
    Array(JSON.parse(launch("rehearsal_run.rehearsal_outcome", "run=#{run}").first)).first
  end

  def rows = JSON.parse(File.read(rows_path))

  def write_rows(document) = File.write(rows_path, JSON.generate(document))

  def store_widget(id, **state)
    document = rows
    document["records"]["Widget"][id] = { "sku" => { "value" => id }, "status" => "listed" }.merge(state)
    write_rows(document)
  end

  def verdict_of(record) = record["verdict"]

  def status_of(record) = record["status"]

  # Replaces what the shop's world says about its copy with `body`, inside `rehearsed_by`.
  def declare_copy(body)
    world = File.join(shop, "bluebook", "shop.world")
    File.write(world, File.read(world).sub(/  rehearsed_by\("Memory"\) do\n.*?\n  end\n/m,
                                           "  rehearsed_by(\"Memory\") do\n    #{body}\n  end\n"))
  end

  def overlay(name, text = "Hecks.hecksagon \"Shop\" do\nend\n")
    FileUtils.mkdir_p(File.join(shop, "bluebook", "environments"))
    File.write(File.join(shop, "bluebook", "environments", "#{name}.hecksagon"), text)
  end

  # The shop's own hecksagon binds only Order, so Widget is bound in an overlay or nowhere.
  def bind_only_order
    File.write(File.join(shop, "bluebook", "shop.hecksagon"),
               "Hecks.hecksagon \"Shop\" do\n  Shop::Order.persisted_by \"PostgresEra\"\nend\n")
  end

  def limits_of(record) = record["unchecked"].map { |limit| limit["what"] }

  def held_current_shape
    document = rows
    document["eras"][0]["held_text"] = File.read(File.join(shop, "bluebook", "shop.bluebook"))
    write_rows(document)
  end

  it "would mint when an edge leads on and nothing stored is refused", :aggregate_failures, :process do
    record = rehearse

    expect([status_of(record), verdict_of(record)]).to eq(%w[judged would_mint])
    expect(record["minting"]).to eq("next")
  end

  it "names the era held and the era a mint would hold", :aggregate_failures, :process do
    state = rehearse

    expect(state["before"]).to eq("708420")
    expect(state["after"]).to eq("7edd70")
  end

  it "says what it did not check", :process do
    unchecked = rehearse["unchecked"].map { |limit| limit["what"] }

    expect(unchecked).to include("the mint itself")
  end

  it "says that an attached bluebook's shape is not an era of the domain", :aggregate_failures, :process do
    File.write(File.join(shop, "bluebook", "vendored.bluebook"),
               "Hecks.bluebook \"Vendored\" do\n  aggregate \"Page\" do\n    attribute :slug, Slug\n    " \
               "identified_by :slug\n    value_object(\"Slug\") { attribute :value, String }\n  end\nend\n")
    unchecked = rehearse["unchecked"].map { |limit| limit["what"] }

    expect(unchecked).to include("the shape of the attached bluebooks (Vendored)")
  end

  it "would mint nothing when the shape stands", :aggregate_failures, :process do
    held_current_shape
    state = rehearse

    expect(state["minting"]).to eq("none")
    expect(state["verdict"]).to eq("would_mint")
  end

  it "would hold the first era when a copy is asked to be empty", :aggregate_failures, :process do
    declare_copy('mode "empty"')
    record = rehearse

    expect(record["minting"]).to eq("first")
    expect(verdict_of(record)).to eq("would_mint")
  end

  it "needs an edge when the shape changed and none leads to it", :aggregate_failures, :process do
    FileUtils.rm_rf(File.join(shop, "bluebook", "translations"))
    record = rehearse

    expect([status_of(record), verdict_of(record)]).to eq(%w[withheld needs_edge])
    expect(record["edge_present"]).to be(false)
  end

  describe "how much was audited" do
    it "counts the rows and aggregates the audit read", :aggregate_failures, :process do
      record = rehearse

      expect(record["audited"]).to be(true)
      expect(record.values_at("rows_examined", "aggregates_examined")).to eq([3, 2])
    end

    it "says no row was read when the shape stands", :aggregate_failures, :process do
      held_current_shape
      record = rehearse

      expect(record["audited"]).to be(false)
      expect(record["reason"]).to eq("no mint is needed at this shape, so no stored row was examined")
    end

    it "carries that limit in what a clean verdict did not check", :process do
      held_current_shape

      expect(limits_of(rehearse)).to include("the stored rows")
    end

    it "shows the head and journal counts side by side", :aggregate_failures, :process do
      record = rehearse

      expect(record["head_rows"]).to eq(3)
      expect(record["census"]).to include("aggregate" => "Widget", "head" => 2, "journal" => 2)
    end

    it "says the audit reads the journal and not the head tables", :process do
      expect(limits_of(rehearse)).to include("the head tables")
    end
  end

  describe "a copy that holds no row of the domain" do
    before { write_rows("eras" => rows["eras"], "records" => {}) }

    it "is not rehearsed: the run ends empty_copy", :aggregate_failures, :process do
      record = rehearse

      expect([status_of(record), verdict_of(record)]).to eq(%w[withheld empty_copy])
      expect(record["copy_empty"]).to be(true)
    end

    it "says what the copy lacked and what to set", :aggregate_failures, :process do
      reason = rehearse["refusal"]

      expect(reason).to include("no rows for domain Shop")
      expect(reason).to include("name the document that holds the stored records in `rows`")
    end
  end

  describe "the environment" do
    it "is reported as a fact, and is none when the domain has no overlay", :aggregate_failures, :process do
      record = rehearse

      expect(record.dig("environment_loaded", "name")).to eq("")
      expect(record.dig("environment_loaded", "source")).to eq("none")
    end

    it "defaults to production when the domain has that overlay", :aggregate_failures, :process do
      overlay("production")
      loaded = rehearse["environment_loaded"]

      expect(loaded).to include("name" => "production", "source" => "default")
      expect(loaded["file"]).to end_with("environments/production.hecksagon")
    end

    it "takes the environment the world names", :aggregate_failures, :process do
      overlay("staging")
      declare_copy("rows \"../rehearsal/rows.json\"\n    environment \"staging\"")

      expect(rehearse["environment_loaded"]).to include("name" => "staging", "source" => "world")
    end

    it "names the environment, the file and the aggregate when a bind is missing", :aggregate_failures do
      bind_only_order
      overlay("staging")
      reason = rehearse["refusal"]

      expect(reason).to include("Shop::Widget has no persisted_by bind")
      expect(reason).to include("no environment overlay (none named", "overlays this domain holds: staging")
    end

    it "boots when the overlay that carries the binds is the one loaded", :aggregate_failures, :process do
      bind_only_order
      overlay("production", "Hecks.hecksagon \"Shop\" do\n  Shop::Widget.persisted_by \"PostgresEra\"\nend\n")

      expect(verdict_of(rehearse)).to eq("would_mint")
    end
  end

  it "reports a run this process does not hold as unknown, not as a state", :aggregate_failures do
    answer, status = launch("rehearsal_run.rehearsal_outcome", "run=never-made")

    expect(answer).to include("no run \"never-made\" is held by this process")
    expect(status).to eq(1)
  end

  describe "a stored row the new shape refuses" do
    before { store_widget("w3", "size" => { "value" => "small" }, "status" => "gone") }

    it "would refuse, naming the row and the rule", :aggregate_failures, :process do
      record = rehearse
      row = record.dig("refused_rows", 0)

      expect([status_of(record), verdict_of(record)]).to eq(%w[withheld would_refuse])
      expect(row).to include("aggregate" => "Widget", "id" => "w3", "rule" => "lifecycle")
    end

    it "counts the rows it was refused for", :process do
      expect(rehearse["refusal_total"]).to eq(1)
    end
  end

  it "holds only the first fifty rows and counts them all", :aggregate_failures, :process do
    55.times { |n| store_widget("w#{n + 10}", "size" => { "value" => "small" }, "status" => "gone") }
    state = rehearse

    expect(state.fetch("refused_rows").size).to eq(50)
    expect(state["refusal_total"]).to eq(55)
  end

  it "cannot boot a domain that does not load", :aggregate_failures do
    File.write(File.join(shop, "bluebook", "shop.bluebook"), "Hecks.bluebook \"Shop\" do\n  aggregate \"Widget\" do\n")
    record = rehearse

    expect([status_of(record), verdict_of(record)]).to eq(%w[withheld cannot_boot])
  end

  it "is refused when the world declares no copy of the data", :aggregate_failures do
    File.write(File.join(shop, "bluebook", "shop.world"), "Hecks.world \"Shop\" do\n  realm \"Fixtures\"\nend\n")
    record = rehearse

    expect(status_of(record)).to eq("refused")
    expect(record["refusal"]).to include("declares no `rehearsed_by`")
  end

  it "is refused when the world holds a literal connection instead of an environment name", :aggregate_failures do
    world = File.join(shop, "bluebook", "shop.world")
    File.write(world, File.read(world).sub("rows \"../rehearsal/rows.json\"", "database \"postgres://localhost/shop\""))
    record = rehearse

    expect(status_of(record)).to eq("refused")
    expect(record["refusal"]).to include("name the environment variable")
  end

  it "is refused when this install is not the pin", :process do
    record = rehearse("pinned", "pin=9.9.9")

    expect(record["refusal"]).to include("not the pin 9.9.9")
  end

  it "keeps no rehearsal: the aggregate is bound to Memory" do
    aggregate = @hecks.registry.bluebooks.fetch("Hecks").aggregate("RehearsalRun")

    expect(@hecks.registry.repository("Hecks", aggregate).adapter).to be_a(Hecks::Adapters::Memory)
  end
end

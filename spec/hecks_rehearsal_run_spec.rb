require "spec_helper"
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

  before { FileUtils.cp_r(File.join(InMemoryDomain::ROOT, "spec/fixtures/rehearsal/shop"), shop) }

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

  def verdict_of(record) = record.dig("verdict", "value")

  def status_of(record) = record["status"]

  def held_current_shape
    document = rows
    document["eras"][0]["held_text"] = File.read(File.join(shop, "bluebook", "shop.bluebook"))
    write_rows(document)
  end

  it "would mint when an edge leads on and nothing stored is refused", :aggregate_failures do
    record = rehearse

    expect([status_of(record), verdict_of(record)]).to eq(%w[judged would_mint])
    expect(record.dig("minting", "value")).to eq("next")
  end

  it "names the era held and the era a mint would hold", :aggregate_failures do
    state = rehearse

    expect(state.dig("before", "value")).to eq("708420")
    expect(state.dig("after", "value")).to eq("7edd70")
  end

  it "says what it did not check" do
    unchecked = rehearse["unchecked"].map { |limit| limit["what"] }

    expect(unchecked).to include("the mint itself")
  end

  it "says that an attached chapter's shape is not an era of the domain", :aggregate_failures do
    File.write(File.join(shop, "bluebook", "vendored.bluebook"),
               "Hecks.bluebook \"Vendored\" do\n  aggregate \"Page\" do\n    attribute :slug, Slug\n    " \
               "identified_by :slug\n    value_object(\"Slug\") { attribute :value, String }\n  end\nend\n")
    unchecked = rehearse["unchecked"].map { |limit| limit["what"] }

    expect(unchecked).to include("the shape of the attached chapters (Vendored)")
  end

  it "would mint nothing when the shape stands", :aggregate_failures do
    held_current_shape
    state = rehearse

    expect(state.dig("minting", "value")).to eq("none")
    expect(state.dig("verdict", "value")).to eq("would_mint")
  end

  it "would hold the first era when none is held" do
    write_rows("eras" => [], "records" => {})

    expect(rehearse.dig("minting", "value")).to eq("first")
  end

  it "needs an edge when the shape changed and none leads to it", :aggregate_failures do
    FileUtils.rm_rf(File.join(shop, "bluebook", "translations"))
    record = rehearse

    expect([status_of(record), verdict_of(record)]).to eq(%w[withheld needs_edge])
    expect(record.dig("edge_present", "value")).to be(false)
  end

  describe "a stored row the new shape refuses" do
    before { store_widget("w3", "size" => { "value" => "small" }, "status" => "gone") }

    it "would refuse, naming the row and the rule", :aggregate_failures do
      record = rehearse
      row = record.dig("refused_rows", 0)

      expect([status_of(record), verdict_of(record)]).to eq(%w[withheld would_refuse])
      expect(row).to include("aggregate" => "Widget", "id" => "w3", "rule" => "lifecycle")
    end

    it "counts the rows it was refused for" do
      expect(rehearse.dig("refusal_total", "value")).to eq(1)
    end
  end

  it "holds only the first fifty rows and counts them all", :aggregate_failures do
    55.times { |n| store_widget("w#{n + 10}", "size" => { "value" => "small" }, "status" => "gone") }
    state = rehearse

    expect(state.fetch("refused_rows").size).to eq(50)
    expect(state.dig("refusal_total", "value")).to eq(55)
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
    expect(record.dig("refusal", "value")).to include("declares no `rehearsed_by`")
  end

  it "is refused when the world holds a literal connection instead of an environment name", :aggregate_failures do
    world = File.join(shop, "bluebook", "shop.world")
    File.write(world, File.read(world).sub("rows \"../rehearsal/rows.json\"", "database \"postgres://localhost/shop\""))
    record = rehearse

    expect(status_of(record)).to eq("refused")
    expect(record.dig("refusal", "value")).to include("name the environment variable")
  end

  it "is refused when this install is not the pin" do
    record = rehearse("pinned", "pin=9.9.9")

    expect(record.dig("refusal", "value")).to include("not the pin 9.9.9")
  end

  it "keeps no rehearsal: the aggregate is bound to Memory" do
    aggregate = @hecks.registry.bluebooks.fetch("Hecks").aggregate("RehearsalRun")

    expect(@hecks.registry.repository("Hecks", aggregate).adapter).to be_a(Hecks::Adapters::Memory)
  end
end

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/main_integration/local_overlay"

# A checkout's gitignored local hecksagon outlives an aggregate the bluebook retires. A bind there
# to an aggregate the bluebook does not declare is left out and said, so a stale overlay never
# stops the launcher opening; the same bind in a committed hecksagon or environment is refused.
RSpec.describe "a stale bind in a local hecksagon" do
  let(:dir) { Dir.mktmpdir("stale-local") }

  after { FileUtils.remove_entry(dir) }

  BLUEBOOK = <<~BLUEBOOK.freeze
    Hecks.bluebook "Shelf" do
      vision "one kept thing, to prove a stale local bind is left out"
      core

      aggregate "Book" do
        description "a book"
        identified_by :ref
        value_object("Ref") { attribute :value, String }
        attribute :ref, Ref

        command "Shelve" do
          goal "shelve a book"
          attribute :ref, Ref
          emits "BookShelved"
        end
      end
    end
  BLUEBOOK

  STALE = <<~HECKSAGON.freeze
    Hecks.hecksagon "Shelf" do
      Shelf::Retired.persisted_by("Memory")
    end
  HECKSAGON

  def write(relative, content)
    FileUtils.mkdir_p(File.dirname(File.join(dir, relative)))
    File.write(File.join(dir, relative), content)
  end

  # Writes the Shelf domain with the stale bind in the file named, and the plain one elsewhere.
  def shelf(stale_in:)
    write("shelf.bluebook", BLUEBOOK)
    write("shelf.hecksagon", "Hecks.hecksagon \"Shelf\" do\n  Shelf::Book.persisted_by(\"Memory\")\nend\n")
    write(stale_in, STALE)
  end

  def boot(environment: nil) = Hecks.boot(dir, environment: environment, install_driving: false)

  def bound(dispatcher) = dispatcher.registry.hecksagon("Shelf").binds.filter_map(&:aggregate)

  it "opens over a local hecksagon binding a retired aggregate, saying it was left out" do
    shelf(stale_in: "shelf.local.hecksagon")
    expect { boot }.to output(/local hecksagon binds Shelf::Retired.*left out/).to_stderr
  end

  it "leaves the retired aggregate's bind out and keeps the declared one" do
    shelf(stale_in: "shelf.local.hecksagon")
    expect(bound(silence_stderr { boot })).to eq(%w[Shelf::Book])
  end

  it "still refuses the bind in the committed hecksagon" do
    shelf(stale_in: "shelf.hecksagon")
    expect { boot }.to raise_error(Hecks::Runtime::WiringError, /Shelf::Retired is bound but not declared/)
  end

  it "still refuses the bind in a named environment's overlay" do
    shelf(stale_in: "environments/production.hecksagon")
    expect { boot(environment: "production") }.to raise_error(Hecks::Runtime::WiringError, /Shelf::Retired is bound/)
  end

  it "rewrites hecks.local.hecksagon from the rows, dropping a line the rows do not name" do
    write(Hecks::Adapters::MainIntegration::LocalOverlay::PATH, "  Hecks::Retired.persisted_by(\"SqlitePersistence\")\n")
    rows = [{ domain: "Hecks", aggregate: "Ticker", checkout: "main", reason: "kept" }]
    Hecks::Adapters::MainIntegration::LocalOverlay.new(dir, rows, "main").write
    expect(File.read(File.join(dir, Hecks::Adapters::MainIntegration::LocalOverlay::PATH))).not_to include("Retired")
  end

  def silence_stderr
    held = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = held
  end
end

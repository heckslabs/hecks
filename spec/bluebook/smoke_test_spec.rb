require "spec_helper"
require "hecks/bluebook/smoke_test"
require "tmpdir"

RSpec.describe Hecks::Bluebook::SmokeTest do
  SMOKE_ITEM_AGGREGATE = <<~RUBY.freeze
    aggregate "Item" do
      identified_by :name
      attribute :name, Name
      value_object "Name" do
        attribute :value, String
      end
      command "Add" do
        attribute :name, Name
      end
    end
  RUBY

  # A command acting on an existing record without `reference_to Item` looks creating.
  # It reloads and checks clean, and only breaks when dispatched twice against one identity.
  SMOKE_ITEM_WITH_TOUCH = <<~RUBY.freeze
    aggregate "Item" do
      identified_by :name
      attribute :name, Name
      value_object "Name" do
        attribute :value, String
      end
      command "Add" do
        attribute :name, Name
      end
      command "Touch" do
        attribute :name, Name
      end
    end
  RUBY

  SMOKE_TAG_AGGREGATE = <<~RUBY.freeze

    aggregate "Tag" do
      reference_to Item

      identified_by :item
      command "Attach" do
        reference_to Item
      end
    end
  RUBY

  SMOKE_HEKI_HECKSAGON = <<~RUBY.freeze
    Hecks.hecksagon "SmokeWidget" do
      SmokeWidget::Item.persisted_by("Heki")
    end
  RUBY

  SMOKE_HEKI_WORLD = <<~RUBY.freeze
    Hecks.world "SmokeWidget" do
      realm "Acme"
      persisted_by("Heki") { dir "data" }
    end
  RUBY

  around do |example|
    @root = Dir.mktmpdir("hecks-smoke-")
    example.run
  ensure
    FileUtils.remove_entry(@root) if @root
  end

  def write_domain(domain, body, realm: "Acme")
    directory = File.join(@root, domain, "bluebook")
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "#{domain}.bluebook"), "Hecks.bluebook #{domain.inspect} do\n#{body}\nend\n")
    File.write(File.join(directory, "#{domain}.world"), "Hecks.world #{domain.inspect} do\n  realm #{realm.inspect}\nend\n")
    File.join(@root, domain)
  end

  # A well-formed domain whose one aggregate persists in a Heki file, bound by its own hecksagon and world.
  def write_heki_domain
    dir = write_domain("SmokeWidget", SMOKE_ITEM_AGGREGATE)
    File.write(File.join(dir, "bluebook", "SmokeWidget.hecksagon"), SMOKE_HEKI_HECKSAGON)
    File.write(File.join(dir, "bluebook", "SmokeWidget.world"), SMOKE_HEKI_WORLD)
    dir
  end

  def item_repository(runtime)
    runtime.registry.repository("SmokeWidget", runtime.registry.bluebook("SmokeWidget").aggregate("Item"))
  end

  # Persists one real record in the domain's Heki file, as a run outside the smoke test would.
  def seed_real_record(dir)
    runtime = Hecks.boot(dir, install_driving: false)
    runtime.dispatch_flat("SmokeWidget::Item.Add", name: { value: "smoke-test" })
    expect(item_repository(runtime).all.size).to eq(1)
  end

  # A fresh boot re-reads the Heki file from disk instead of trusting in-memory objects.
  def persisted_item_ids(dir)
    item_repository(Hecks.boot(dir, install_driving: false)).all.map(&:id)
  end

  it "dispatches cleanly against a real, well-formed domain — no failures" do
    dir = write_domain("SmokeWidget", SMOKE_ITEM_AGGREGATE)

    expect(described_class.call(dir)).to eq([])
  end

  it "catches a command wrongly classified as creating — reloads clean, only breaks on dispatch", :aggregate_failures do
    failures = described_class.call(write_domain("SmokeWidget", SMOKE_ITEM_WITH_TOUCH))

    expect(failures.size).to eq(1)
    expect(failures.first.command).to eq("Touch")
    expect(failures.first.error).to include("AlreadyExists")
  end

  it "walks aggregates in declaration order, so a later aggregate can reference an earlier one's real id" do
    dir = write_domain("SmokeWidget", SMOKE_ITEM_AGGREGATE + SMOKE_TAG_AGGREGATE)

    expect(described_class.call(dir)).to eq([])
  end

  it "reports nothing for an empty directory with no discoverable domain" do
    dir = File.join(@root, "empty")
    FileUtils.mkdir_p(dir)

    expect(described_class.call(dir)).to eq([])
  end

  # A synthesized command once collided with a real record in a file-backed store. This proves a
  # Heki-bound record survives a smoke run, whatever `.hecksagon` and `.world` bind to.
  it "never touches the target directory's own real persisted data, however it's really bound" do
    dir = write_heki_domain
    seed_real_record(dir)
    described_class.call(dir)

    expect(persisted_item_ids(dir)).to eq(["smoke-test"])
  end
end

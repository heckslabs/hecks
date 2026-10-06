require "spec_helper"

# While the Hecks chapter's hecksagon builds, a real `Hecks::Release` is taken off the gem so
# the chapter can name an aggregate `Hecks::Release`. A chapter that `attaches` loads is
# ordinary code and must see the real module.
RSpec.describe Hecks::Bluebook::DSL::HecksagonBuilder, ".build" do
  let(:builder) { described_class }
  let(:registry) do
    aggregate = Struct.new(:hecks_name).new("Release")
    chapter   = Struct.new(:aggregates).new([aggregate])
    Struct.new(:chapter) do
      def bluebook(_name) = chapter
      def mark_bounded(_name) = nil
    end.new(chapter)
  end

  before do
    require_relative "../lib/hecks/release/gem_pin"
    allow(Hecks).to receive(:current_registry).and_return(registry)
    @real = Hecks::Release
  end

  def missing_constant_error
    Hecks::NotAnAggregate
  rescue NameError => e
    e
  end

  # Stubs the chapter load to record what a chapter loaded by `attaches` sees; answers the record.
  def record_chapter_load
    seen = {}
    allow(Hecks::Chapters).to receive(:load!) do |_name|
      seen[:defined] = Hecks.const_defined?(:Release, false)
      seen[:module]  = Hecks.const_get(:Release)
      seen[:missing] = missing_constant_error
    end
    seen
  end

  # Builds a hecksagon that attaches a chapter; answers whether the real module is visible
  # right after.
  def release_visible_after_attach
    visible = nil
    builder.build("Hecks") do
      attaches "Bluebook"
      visible = Hecks.const_defined?(:Release, false)
    end
    visible
  end

  it "shows a chapter loaded by `attaches` the real module", :aggregate_failures do
    seen = record_chapter_load
    release_visible_after_attach

    expect(seen[:defined]).to be(true)
    expect(seen[:module]).to equal(@real)
    expect(seen[:missing]).to be_a(NameError)
  end

  it "shadows the real module again once the attach is done", :aggregate_failures do
    record_chapter_load

    expect(release_visible_after_attach).to be(false)
    expect(Hecks::Release).to equal(@real)
  end

  it "leaves the real modules in place after a build that raises", :aggregate_failures do
    expect { builder.build("Hecks") { raise "boom" } }.to raise_error("boom")
    expect(Hecks::Release).to equal(@real)
  end

  it "keeps the build's state on its own thread" do
    seen = nil
    klass = described_class
    klass.build("Hecks") { seen = Thread.new { [klass.building, klass.collector] }.value }
    expect(seen).to eq([nil, nil])
  end
end

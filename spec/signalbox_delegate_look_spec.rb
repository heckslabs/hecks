# frozen_string_literal: true

require "spec_helper"
require "hecks/signalbox/adapters/looking"

# The pressure beat reads what Delegate's last fill and shed did from their records, and decides
# nothing about it: Signalbox's rulings do.
# Each row: what the case is, Delegate's last fill report, its Shed records, and what is read.
DELEGATE_LOOKS = [
  ["the work item the last fill started", "load 3.1; started 2 of cap 4\nwould start board-tiles: add a tile", [],
   { fill_subject: "board-tiles", fill_delegate: "start" }],
  ["the first work item a fill that started nothing left waiting",
   "load 9.4\nskipped: load 9.4: nothing starts; 3 waiting, first tiles-a, tiles-b", [],
   { fill_subject: "tiles-a", fill_delegate: "wait" }],
  ["a fill with nothing planned", "load 1.0; this fill would start 0", [],
   { fill_subject: "nothing-planned", fill_delegate: "none" }],
  ["the work item the last shed asked to yield", "", [{ reading: "load-6", work: "" }, { reading: "load-7", work: "tiles" }],
   { shed_subject: "tiles", shed_delegate: "shed" }],
  ["a last shed that spared every one", "", [{ reading: "load-8", work: "" }], { shed_subject: "load-8", shed_delegate: "none" }]
].freeze

RSpec.describe Hecks::Adapters::Looking::DelegateLook do
  # A registry holding the Hecks domain's `Dispatch` and `Shed` records.
  def registry_of(held)
    kinds = held.keys.map { |name| Struct.new(:hecks_name).new(name) }
    Struct.new(:kinds, :held) do
      def bluebook(_name) = Struct.new(:aggregates).new(kinds)
      def repository(_domain, kind) = Struct.new(:all).new(held.fetch(kind.hecks_name))
    end.new(kinds, held)
  end

  DELEGATE_LOOKS.each do |name, report, sheds, read|
    it "reads #{name}" do
      registry = registry_of("Dispatch" => [{ report: report }], "Shed" => sheds)

      expect(described_class.new(registry).facts).to include(read)
    end
  end

  it "says Delegate had nothing to fill and shed none without the Hecks domain" do
    expect(described_class.new(nil).facts).to eq(fill_subject: "nothing-planned", fill_delegate: "none",
                                                 shed_subject: "nothing-shed", shed_delegate: "none")
  end
end

require "spec_helper"
require "hecks/hecks/adapters/work_limits"

# A registry with one Tickets world and, when given, one WorkCap record.
module MovingCapRegistry
  World = Struct.new(:lines) do
    def for_verb(verb) = lines[verb]
  end

  # A kept field, unwrapped by its `value` as a runtime value object is.
  Level = Struct.new(:value)

  Repository = Struct.new(:held) do
    def find(_key) = held
  end

  Held = Struct.new(:lines, :record) do
    def world(_name) = World.new(lines)

    def bluebook(_name) = Struct.new(:aggregates).new([Struct.new(:hecks_name).new("WorkCap")])

    def repository(_domain, _aggregate) = Repository.new(record)
  end
end

# The fill reads the moving cap from the kept WorkCap record while the owner has the Tickets world's
# `work_cap` line say `moves: true`, held inside that line's bounds; with `moves: false`, or before
# any reading opened the record, it reads the fixed `work_limit` cap. Reading a record turns no
# setting, so nothing asks the resident to retire.
RSpec.describe Hecks::Adapters::MovingCap do
  def registry(moves, current) = MovingCapRegistry::Held.new(lines(moves), current && record(current))

  def lines(moves) = { "work_limit" => { cap: 7 }, "work_cap" => { moves: moves, least: 2, most: 6 } }

  def record(current) = { current: MovingCapRegistry::Level.new(current), reason: "raised: five calm readings" }

  it "reads the record's cap while the cap moves" do
    expect(Hecks::Adapters::WorkLimits.cap(registry(true, 5))).to eq(5)
  end

  it "holds the record's cap inside the owner's bounds" do
    expect(Hecks::Adapters::WorkLimits.cap(registry(true, 9))).to eq(6)
  end

  it "reads the fixed cap when the cap does not move, or no reading opened the record" do
    expect([registry(false, 5), registry(true, nil)].map { |held| Hecks::Adapters::WorkLimits.cap(held) }).to eq([7, 7])
  end

  it "says where the moving cap stands, for the Settings page's line" do
    expect(described_class.standing(registry(true, 3)))
      .to eq(current: 3, least: 2, most: 6, reason: "raised: five calm readings")
  end
end

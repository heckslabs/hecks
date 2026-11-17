# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

require "hecks/hecks/adapters/dial_turning"

# `Dial.turn!` sets one of the machine's operating settings from a command: only a setting the
# `Turnable` rows list, only to a value inside its row's bounds, by writing the checkout's
# gitignored `turned.local.world`.
RSpec.describe Hecks::Adapters::DialTurning do
  let(:registry) { boot_hecks_in_memory.registry }
  let(:dial) { registry.bluebook("Hecks").aggregates.find { |aggregate| aggregate.hecks_name == "Dial" } }
  let(:rows) { described_class::Turnables.of(dial) }
  # The worlds as a booted registry answers them, here one world of two verbs.
  let(:worlds) do
    { "work_limit"        => { adapter: "WorkLimits", cap: 7, urgent_reserve: 1 },
      "dispatch_max_load" => { adapter: "Dispatch", limit: 10.0 } }
  end
  let(:standing) do
    world = Struct.new(:verbs) { def for_verb(verb) = verbs.fetch(verb.to_s, {}) }.new(worlds)
    Struct.new(:held) { def world(_name) = held }.new(world)
  end

  # The checkouts whose resident a turn asked to retire.
  def retired = (@retired ||= [])

  def turning(folder, running: true)
    retire = ->(root) { (retired << root) && running }
    described_class.new(aggregate: dial, registry: standing, settings: { directory: folder, retire: retire })
  end

  def refused(folder)
    turning(folder).set(setting: "work_limit.cap", becomes: "999")
  rescue Hecks::Adapters::ConsoleCapture::Failure
    nil
  end

  def turned(folder) = File.read(File.join(folder, "turned.local.world"))

  it "writes the verb's whole line with the one key changed, since a world merges a verb whole" do
    Dir.mktmpdir do |folder|
      turning(folder).set(setting: "work_limit.cap", becomes: "9")
      expect(turned(folder)).to include("Hecks.world \"Tickets\" do\n  work_limit \"WorkLimits\", cap: 9, urgent_reserve: 1\nend")
    end
  end

  it "asks the checkout's resident to retire, so the setting is in force at once" do
    Dir.mktmpdir do |folder|
      turning(folder).set(setting: "work_limit.cap", becomes: "9")
      expect(retired).to eq([File.expand_path("../../..", folder)])
    end
  end

  it "says the resident restarts when one was running" do
    Dir.mktmpdir do |folder|
      said = turning(folder).set(setting: "work_limit.cap", becomes: "9")
      expect(said[:output][:value]).to end_with("in force for the next command (the resident restarts)")
    end
  end

  it "says the setting is in force when no resident was running" do
    Dir.mktmpdir do |folder|
      said = turning(folder, running: false).set(setting: "work_limit.cap", becomes: "9")
      expect(said[:output][:value]).to end_with("; in force for the next command")
    end
  end

  it "retires nothing when the turn is refused" do
    Dir.mktmpdir do |folder|
      refused(folder)
      expect(retired).to be_empty
    end
  end

  it "says what the setting is now and what it was" do
    Dir.mktmpdir do |folder|
      said = turning(folder).set(setting: { value: "dispatch_max_load.limit" }, becomes: { value: "8" })
      expect(said[:output][:value]).to start_with("dispatch_max_load.limit is 8.0, was 10.0; written to ")
    end
  end

  it "keeps the lines the file already holds when another setting is turned" do
    Dir.mktmpdir do |folder|
      turning(folder).set(setting: "work_limit.cap", becomes: "9")
      turning(folder).set(setting: "dispatch_max_load.limit", becomes: "8")
      expect(turned(folder).scan(/^  \w+/).map(&:strip)).to eq(%w[work_limit dispatch_max_load])
    end
  end

  it "refuses a value outside the row's bounds, and writes nothing", :aggregate_failures do
    Dir.mktmpdir do |folder|
      expect { turning(folder).set(setting: "work_limit.cap", becomes: "999") }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, "work_limit.cap is turned between 1 and 20, not to 999")
      expect(Dir.children(folder)).to be_empty
    end
  end

  it "refuses a value that is not of the row's kind" do
    Dir.mktmpdir do |folder|
      expect { turning(folder).set(setting: "work_limit.cap", becomes: "many") }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, 'work_limit.cap takes a integer, not "many"')
    end
  end

  it "refuses a setting that has no row, naming the ones that do" do
    Dir.mktmpdir do |folder|
      expect { turning(folder).set(setting: "session_grace.seconds", becomes: "1") }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /is not a setting a turn sets; the settings are work_limit/)
    end
  end

  it "reads a turned value over the one a process booted with", :aggregate_failures do
    Dir.mktmpdir do |folder|
      turning(folder).set(setting: "work_limit.cap", becomes: "9")
      cap = described_class::Standing.rows(registry, directory: folder).find { |row| row[:setting] == "work_limit.cap" }
      expect(cap).to include(value: 9, turned: true)
    end
  end

  it "turns a switch on or off" do
    expect(described_class::Turnables.value({ setting: "s.k", kind: "switch" }, "off")).to be(false)
  end

  it "lists only settings the committed world declares, so a row cannot name what is not there" do
    missing = rows.reject do |row|
      verb, key = row[:setting].split(".")
      registry.world(row[:world])&.for_verb(verb)&.key?(key.to_sym)
    end
    expect(missing.map { |row| row[:setting] }).to be_empty
  end
end

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

  # Turns a setting in a new folder and answers what the write renamed and what is left there.
  def turned_through_rename
    Dir.mktmpdir do |folder|
      allow(File).to receive(:rename).and_call_original
      turning(folder).set(setting: "work_limit.cap", becomes: "9")
      return [Dir.children(folder), File.method(:rename)]
    end
  end

  it "writes through a temp file renamed into place, leaving none behind", :aggregate_failures do
    children, = turned_through_rename
    expect(File).to have_received(:rename).with(/turned\.local\.world\.\d+\.tmp\z/, /turned\.local\.world\z/)
    expect(children).to eq(["turned.local.world"])
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

  it "turns a choice to one of its words and refuses another", :aggregate_failures do
    row = { setting: "s.k", kind: "choice", least: "impacted|quick|off" }
    expect(described_class::Turnables.value(row, "quick")).to eq("quick")
    expect { described_class::Turnables.value(row, "some") }.to raise_error(ArgumentError, /impacted, quick, off, not "some"/)
  end

  # Turns the verification setting to a word and answers its row as the board reads it.
  def verification_row_after_turning_to(word)
    worlds["main_verification"] = { adapter: "MainVerification", workers: 2, verifies: "impacted" }
    Dir.mktmpdir do |folder|
      turning(folder).set(setting: "main_verification.verifies", becomes: word)
      described_class::Standing.rows(registry, directory: folder).find { |r| r[:setting] == "main_verification.verifies" }
    end
  end

  it "reads a turned word back over the one a process booted with" do
    expect(verification_row_after_turning_to("off")).to include(value: "off", turned: true, kind: "choice")
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

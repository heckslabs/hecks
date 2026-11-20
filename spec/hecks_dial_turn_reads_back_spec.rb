# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

require "hecks/hecks/adapters/dial_turning"

# Every turn `Dial.turn!` accepts changes what the world reads back: each `Turnable` row, turned in
# a temp folder to a value inside its bounds that the committed world does not hold, writes a
# `turned.local.world` that the real world loader reads back at the new value. A row the world
# cannot hold is refused by the turn, and fails here.
RSpec.describe Hecks::Adapters::DialTurning do
  let(:registry) { boot_hecks_in_memory.registry }
  let(:dial) { registry.bluebook("Hecks").aggregates.find { |aggregate| aggregate.hecks_name == "Dial" } }
  let(:rows) { described_class::Turnables.of(dial) }

  # What the committed world holds for a row's setting.
  def committed(row)
    verb, key = row[:setting].split(".")
    registry.world(row[:world])&.for_verb(verb).to_h[key.to_sym]
  end

  # A value inside the row's bounds, in words, that differs from the committed one.
  def other_than_committed(row)
    held = committed(row)
    case row[:kind]
    when "switch" then held ? "off" : "on"
    when "choice" then row[:least].split("|").find { |word| word != held.to_s }
    else Float(row[:least]).to_s == held.to_f.to_s ? row[:most] : row[:least]
    end
  end

  # Loads a turned file into a fresh registry through the world loader, as a boot reads it.
  def read_back(folder)
    fresh = Hecks::Runtime::Registry.new(root: folder)
    Hecks.with_registry(fresh) { load File.join(folder, described_class::TurnedFile::NAME) }
    fresh
  end

  # Turns one setting in a folder, as `Dial.turn!` does, with no resident to retire.
  def turn_in(folder, setting, text)
    described_class.new(aggregate: dial, registry: registry, settings: { directory: folder, retire: ->(_) { false } })
                   .set(setting: setting, becomes: text)
  end

  # Turns one row in its own folder and answers the value it was turned to and the value read back.
  def turned_and_read(row)
    text = other_than_committed(row)
    verb, key = row[:setting].split(".")
    Dir.mktmpdir do |folder|
      turn_in(folder, row[:setting], text)
      [described_class::Turnables.value(row, text), read_back(folder).world(row[:world]).for_verb(verb)[key.to_sym]]
    end
  end

  it "reads back every accepted turn at the value it was turned to" do
    misread = rows.map { |row| [row[:setting], *turned_and_read(row)] }.reject { |_, set, read| set == read }
    expect(misread).to be_empty
  end

  it "turns reaping.session_keep down to one hour" do
    row = rows.find { |candidate| candidate[:setting] == "reaping.session_keep" }
    expect(described_class::Turnables.value(row, "1")).to eq(1)
  end

  # Turns the session keep to one hour in a new folder and answers the line it wrote.
  def session_keep_line
    Dir.mktmpdir do |folder|
      turn_in(folder, "reaping.session_keep", "1")
      File.read(File.join(folder, described_class::TurnedFile::NAME))[/^  reaping .*$/]
    end
  end

  it "writes the Hecks world's whole reaping line, keeping the scratch paths", :aggregate_failures do
    line = session_keep_line
    expect(line).to include("session_keep: 1")
    expect(line).to include('worktree_scratch: ["tmp", ".ruby-lsp"')
  end

  # Two turns of different settings in one folder, each by a process that booted before the other.
  def turn_two_settings
    Dir.mktmpdir do |folder|
      turn_in(folder, "signalbox_response.drives", "on")
      turn_in(folder, "reaping.session_keep", "1")
      read_back(folder)
    end
  end

  it "holds both settings when two turns of different settings follow each other", :aggregate_failures do
    read = turn_two_settings
    expect(read.world("Tickets").for_verb("signalbox_response")[:drives]).to be(true)
    expect(read.world("Hecks").for_verb("reaping")[:session_keep]).to eq(1)
  end

  it "settles every Dial.turn! from the launcher, so it answers turned or refused, never just requested" do
    expect(Array(registry.world("Hecks").for_verb("launcher")[:settled])).to include("dial.turn")
  end
end

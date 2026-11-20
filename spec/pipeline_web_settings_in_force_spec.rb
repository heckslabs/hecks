# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "hecks/pipeline_board/adapters/pipeline_web/settings_page"

# The Settings page says which side governs a start now, read from the switches the dispatch
# reads: Signalbox's pressure signal while it is current, the Tickets numbers while it is dark.
RSpec.describe Hecks::Adapters::PipelineBoard::InForce do
  let(:folder) { Dir.mktmpdir }
  let(:lines) { { "signalbox_pressure" => { drives: true }, "work_cap" => { moves: true } } }
  let(:registry) do
    world = Struct.new(:lines) { def for_verb(verb) = lines[verb.to_s] }.new(lines)
    Struct.new(:held) do
      def world(_name) = held
      def bluebook(_name) = nil
    end.new(world)
  end

  after { FileUtils.remove_entry(folder) }

  def path = File.join(folder, "pressure.json")

  def now = Time.utc(2026, 11, 20, 12, 0, 0)

  def dials
    [{ setting: "dispatch_max_load.limit", value: 20.5 }, { setting: "work_limit.cap", value: 7 },
     { setting: "heavy_jobs.cap", value: 4 }, { setting: "main_verification.nice", value: 15 }]
  end

  def post(age:)
    signal = { band: "short", headroom: 900, cores: 6, coders_fit: 0, gates_fit: 1, stale_after: 120,
               posted_at: (now - age).iso8601 }
    File.write(path, JSON.generate(signal))
  end

  def force(setting)
    reading = described_class.reading(registry, path: path, now: now)
    described_class.rows(dials, reading).find { |row| row[:setting] == setting }.fetch(:force)
  end

  def governs(side)
    described_class.governs(dials, described_class.reading(registry, path: path, now: now)).fetch(side)
  end

  context "when the signal is current" do
    before { post(age: 10) }

    it "says Signalbox's mark governs the load, so dispatch_max_load is without effect" do
      expect(force("dispatch_max_load.limit")).to include(state: "without_effect", why: a_string_including("Signalbox"))
    end

    it "names Signalbox as the side that governs the load" do
      expect(governs(:load)).to include(side: "Signalbox")
    end

    it "says heavy_jobs.cap is only an upper bound" do
      expect(force("heavy_jobs.cap")[:why]).to include("upper bound")
    end
  end

  context "when the signal is dark" do
    before { post(age: 500) }

    it "keeps dispatch_max_load in force and says Signalbox's mark stands by" do
      expect(force("dispatch_max_load.limit")).to include(state: "in_force", why: a_string_including("dark"))
    end

    it "names Tickets as the side that governs the load" do
      expect(governs(:load)).to include(side: "Tickets")
    end
  end

  context "when the pressure switch is off" do
    before do
      post(age: 10)
      lines["signalbox_pressure"] = { drives: false }
    end

    it "keeps dispatch_max_load in force and says it stands by until the switch is on" do
      expect(force("dispatch_max_load.limit")[:why]).to include("signalbox_pressure.drives")
    end
  end

  context "when the cap moves or is fixed" do
    it "says work_limit.cap is without effect while the moving cap stands" do
      allow(Hecks::Adapters::MovingCap).to receive(:standing).and_return({ current: 5 })
      expect(force("work_limit.cap")).to include(state: "without_effect")
    end

    it "keeps work_limit.cap in force while the cap is fixed" do
      lines["work_cap"] = { moves: false }
      expect(force("work_limit.cap")).to include(state: "in_force")
    end
  end

  context "when admission and verification are switched" do
    it "says the work cap is without effect once Signalbox admits" do
      lines["admission"] = { signalbox: true }
      expect(force("work_limit.cap")).to include(state: "without_effect", why: a_string_including("admission.signalbox"))
    end

    it "says nice is without effect while local verification is off" do
      lines["main_verification"] = { verifies: "off" }
      expect(force("main_verification.nice")).to include(state: "without_effect")
    end
  end

  it "reads Signalbox's marks beside the Tickets setting they mirror" do
    world = Struct.new(:rows) { def for_verb(verb) = rows.fetch(verb, {}) }.new({ "pressure" => { load_short_percent: 342 } })
    held = Struct.new(:held) { def world(_name) = held }.new(world)
    mark = Hecks::Adapters::PipelineBoard::SignalboxMarks.of(held, cores: 6).first
    expect(mark[:beside]).to eq(setting: "dispatch_max_load.limit", load: 20.52)
  end
end

# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/codebase/gate"

# Helpers for a quick gate started while coders' spec runs hold every heavy-job place.
module QuickGateNoSlotHelpers
  CODEBASE = Hecks::Adapters::Codebase

  # Two spec runs, each holding one of the two places under `dir`.
  def hold_both(dir)
    places = File.join(dir, "heavy-jobs")
    FileUtils.mkdir_p(places)
    Array.new(2) { |index| File.new(File.join(places, "slot-#{index}.lock"), File::CREAT | File::RDWR, 0o600) }
         .each { |file| file.flock(File::LOCK_EX) }
  end

  # The gate tool, answering what its environment says of the heavy-job hold.
  def tool
    child = instance_double(CODEBASE::RubyChild)
    allow(child).to receive(:answer) { "held=#{ENV.fetch(CODEBASE::HeavySlots::HELD, "")}" }
    allow(CODEBASE::RubyChild).to receive(:new).and_return(child)
  end

  # Sets each variable, removing one whose value is nil.
  def restore(values) = values.each { |name, value| ENV[name] = value }

  def gate(stage) = CODEBASE::Gate.run(Struct.new(:root).new(Dir.pwd), [stage])
end

# A landing's quick gate starts while two coders' spec runs hold both places: the quick stage takes
# no place and never waits, and the checks it starts are marked held so none of them queues.
RSpec.describe Hecks::Adapters::Codebase::Gate, "#run while every place is held" do
  include QuickGateNoSlotHelpers

  let(:dir) { Dir.mktmpdir("quick-gate-slots") }

  around do |example|
    names = ["HECKS_CACHE_DIR", "CI", Hecks::Adapters::Codebase::HeavySlots::HELD]
    saved = names.to_h { |name| [name, ENV.fetch(name, nil)] }
    restore(names.to_h { |name| [name, nil] }.merge("HECKS_CACHE_DIR" => dir))
    held = hold_both(dir)
    example.run
  ensure
    held&.each(&:close)
    restore(saved) if saved
    FileUtils.rm_rf(dir)
  end

  before do
    tool
    allow(Hecks::Adapters::Codebase::HeavySlots).to receive(:admitted)
  end

  it "runs the quick stage at once, its checks marked held" do
    expect(gate("quick")).to eq("held=#{Process.pid}")
  end

  it "takes no place for the quick stage" do
    gate("quick")
    expect(Hecks::Adapters::Codebase::HeavySlots).not_to have_received(:admitted)
  end

  it "queues any other stage for a place" do
    gate("pre_push")
    expect(Hecks::Adapters::Codebase::HeavySlots).to have_received(:admitted).with(Dir.pwd, "gate")
  end
end

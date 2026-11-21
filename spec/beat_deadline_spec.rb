# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/beating"

# A beat never outlives its window: the beat that holds the place ends its own process once the
# window passes, so a tick that spins in a resident's child frees the place for the next beat.
# The clock and the ending are stood in for; one example forks a real child that inherits a held
# place and is refused at once.
RSpec.describe "the beat's window" do
  let(:dir) { Dir.mktmpdir("beat-deadline") }
  let(:ended) { Queue.new }
  let(:settings) { { dir: dir, window: 300, sleeper: ->(seconds) { ended << seconds }, ender: -> { ended << :ended } } }

  after { FileUtils.remove_entry(dir) }

  it "ends the beat's process once the window has passed" do
    Hecks::Adapters::Beating.new(settings: settings).take
    expect([ended.pop, ended.pop]).to eq([300, :ended])
  end

  it "refuses at once a forked line that inherits the held place, and finishes" do
    Hecks::Adapters::Beating.new(settings: settings.merge(window: 1)).take
    _, status = Process.wait2(fork { exit!(refused_here? ? 0 : 1) })
    expect(status.exitstatus).to eq(0)
  end

  def refused_here?
    Hecks::Adapters::Beating.held = nil
    Hecks::Adapters::Beating.new(settings: { dir: dir, window: 1, ender: -> {} }).take
    false
  rescue StandardError
    true
  end
end

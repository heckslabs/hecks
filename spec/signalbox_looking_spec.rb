# frozen_string_literal: true

require "spec_helper"
require "hecks/signalbox/adapters/looking"

# Signalbox's pressure beat looks once (ADR 0222, phase 2, the shadow): the copy's view, the machine
# as Roundhouse's meter reads it, the world's marks and Delegate's last fill and shed. Every outside
# read is a stand-in here, and the look compares nothing with a mark.
RSpec.describe Hecks::Adapters::Looking do
  let(:view) { { head: "4116a6d", main: "4116a6d", missing: 0 } }
  let(:machine) { { capacity_mb: 36_864, used_mb: 20_463, load: 700, cores: 6 } }
  let(:delegate) do
    { fill_subject: "pipeline-board-tiles", fill_delegate: "start", shed_subject: "load-7", shed_delegate: "none" }
  end
  let(:looking) do
    described_class.new(settings: { view: -> { view }, machine: -> { machine }, delegate: -> { delegate },
                                    marks: -> { described_class::Marks.new(nil).facts } })
  end

  it "answers every fact the beat records, each as a value" do
    expect(looking.look(beat: { value: "beat-1" })).to include(
      head: { value: "4116a6d" }, used: { value: 20_463 }, age: { value: 0 }, reserve: { value: 8192 },
      coder_draw: { value: 1536 }, fill_delegate: { value: "start" }
    )
  end

  it "keys the beat's two rulings by the beat" do
    expect(looking.look(beat: { value: "beat-1" })).to include(fill_ruling: { value: "beat-1:fill" },
                                                               shed_ruling: { value: "beat-1:shed" })
  end

  it "refuses a look whose machine could not be read" do
    machine[:capacity_mb] = 0

    expect { looking.look(beat: "beat-1") }.to raise_error(described_class::Unlooked, /memory could not be read/)
  end
end

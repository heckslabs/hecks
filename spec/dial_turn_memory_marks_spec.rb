# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

require "hecks/hecks/adapters/dial_turning"

# `Dial.turn!` sets the machine's memory marks, so a stuck MemoryLow is released by one turn and
# put back by another: each mark turns inside its bounds and is refused outside them. The order of a
# pair (recovered under used) is advice in the setting's text, not enforced by a turn.
RSpec.describe Hecks::Adapters::DialTurning do
  let(:registry) { boot_hecks_in_memory.registry }
  let(:dial) { registry.bluebook("Hecks").aggregates.find { |aggregate| aggregate.hecks_name == "Dial" } }

  # Turns one setting in a temp folder, as `Dial.turn!` does, with no resident to retire.
  def turn(setting, text)
    Dir.mktmpdir do |folder|
      described_class.new(aggregate: dial, registry: registry, settings: { directory: folder, retire: ->(_) { false } })
                     .set(setting: "machine_marks.#{setting}", becomes: text)
    end
  end

  {
    "swap_used_mb" => %w[1024 65536], "compressor_gb" => %w[1 64], "free_gb_low" => %w[0.5 32],
    "swap_recovered_mb" => %w[512 2048], "free_gb_recovered" => %w[1 6]
  }.each do |mark, (low, high)|
    it "turns #{mark} to a value inside its bounds" do
      expect([turn(mark, low), turn(mark, high)].map { |told| told[:output][:value] }).to all(include("machine_marks.#{mark} is"))
    end
  end

  %w[swap_used_mb:512 swap_used_mb:70000 compressor_gb:0 compressor_gb:65 free_gb_low:0.1 free_gb_low:40
     swap_recovered_mb:5000 free_gb_recovered:2].each do |pair|
    it "refuses #{pair.tr(":", " turned to ")}" do
      mark, text = pair.split(":")
      expect { turn(mark, text) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure)
    end
  end
end

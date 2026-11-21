# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/safe_signal"

RSpec.describe Hecks::Adapters::SafeSignal do
  let(:sent) { [] }
  let(:killer) { ->(name, target) { sent << [name, target] } }

  # Each file outside this work item's area that still calls Process.kill, with the reason it waits.
  OUT_OF_AREA = {
    "tools/regeneration_run/pool.rb"                      => "regeneration tooling",
    "pipeline_board/adapters/board_supervisor.rb"         => "board supervision",
    "pipeline_board/adapters/pipeline_journal/watch.rb"   => "board journal watch",
    "pipeline_board/adapters/sentinel/standing.rb"        => "board sentinel liveness probe",
    "pipeline_board/adapters/sentinel/host.rb"            => "board sentinel host",
    "pipeline_board/adapters/probe/child.rb"              => "board probe group kill",
    "pipeline_board/adapters/pipeline_web/browser.rb"     => "board browser",
    "agents/adapters/sweeping.rb"                         => "agent sweeping",
    "quality_control/adapters/agent.rb"                   => "quality control group kill",
    "ci_speed/adapters/local_runner/launcher.rb"          => "ci speed group kill"
  }.freeze

  describe "a signal to a group" do
    [1, 0, -1, -5, nil, "1", 1.0].each do |group|
      it "refuses group #{group.inspect} by name and sends nothing", :aggregate_failures do
        expect { described_class.to_group("KILL", group, killer: killer) }
          .to raise_error(described_class::Refused, /refused: group #{Regexp.escape(group.inspect)}/)
        expect(sent).to eq([])
      end
    end

    it "refuses this process's own group" do
      expect { described_class.to_group("TERM", Process.getpgrp, killer: killer) }
        .to raise_error(described_class::Refused, /its own group/)
    end

    it "signals the negated group when it is another's" do
      other = Process.getpgrp + 100_000
      described_class.to_group("TERM", other, killer: killer)
      expect(sent).to eq([["TERM", -other]])
    end
  end

  describe "a signal to one process" do
    [1, 0, -1, nil].each do |pid|
      it "refuses pid #{pid.inspect} by name and sends nothing", :aggregate_failures do
        expect { described_class.to_process("KILL", pid, killer: killer) }
          .to raise_error(described_class::Refused, /refused: process #{Regexp.escape(pid.inspect)}/)
        expect(sent).to eq([])
      end
    end

    it "signals a process above 1" do
      described_class.to_process("TERM", 4242, killer: killer)
      expect(sent).to eq([["TERM", 4242]])
    end
  end

  describe "asking whether a process stands" do
    it "answers false for a pid it refuses, and sends nothing", :aggregate_failures do
      expect(described_class.standing?(1, killer: killer)).to be(false)
      expect(sent).to eq([])
    end

    it "answers true when the process takes the null signal" do
      expect(described_class.standing?(4242, killer: killer)).to be(true)
    end

    it "answers false when the process is gone" do
      gone = ->(_name, _pid) { raise Errno::ESRCH }
      expect(described_class.standing?(4242, killer: gone)).to be(false)
    end
  end

  describe "the source" do
    let(:lib) { File.expand_path("../lib/hecks", __dir__) }
    let(:callers) do
      Dir["#{lib}/**/*.rb"].grep_v(%r{/adapters/safe_signal\.rb\z})
                           .select { |file| File.read(file).match?(/Process\.kill\b/) }
                           .map { |file| file.delete_prefix("#{lib}/") }
    end

    it "calls Process.kill nowhere but SafeSignal and the listed files outside this area" do
      expect(callers - OUT_OF_AREA.keys).to eq([])
    end

    it "lists no file that no longer calls Process.kill" do
      expect(OUT_OF_AREA.keys - callers).to eq([])
    end
  end
end

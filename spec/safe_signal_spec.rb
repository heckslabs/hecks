# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/safe_signal"

RSpec.describe Hecks::Adapters::SafeSignal do
  let(:sent) { [] }
  let(:killer) { ->(name, target) { sent << [name, target] } }

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
    it "answers false for a pid that names no process, and sends nothing", :aggregate_failures do
      expect(described_class.standing?(0, killer: killer)).to be(false)
      expect(sent).to eq([])
    end

    it "asks about process 1 with the null signal, which delivers nothing", :aggregate_failures do
      expect(described_class.standing?(1, killer: killer)).to be(true)
      expect(sent).to eq([[0, 1]])
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

    it "calls Process.kill nowhere but SafeSignal" do
      expect(callers).to eq([])
    end
  end
end

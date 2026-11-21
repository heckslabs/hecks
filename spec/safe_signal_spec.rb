# frozen_string_literal: true

require "spec_helper"
require_relative "../lib/hecks/hecks/adapters/safe_signal"

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
      described_class.to_group("TERM", Process.getpgrp + 100_000, killer: killer)
      expect(sent).to eq([["TERM", -(Process.getpgrp + 100_000)]])
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

  describe "the source" do
    it "has no bare Process.kill with a negated target" do
      bare = Dir[File.expand_path("../lib/**/*.rb", __dir__)].select do |file|
        file != described_class.method(:to_group).source_location.first &&
          File.read(file).match?(/Process\.kill\([^)]*,\s*-/)
      end
      expect(bare).to eq([])
    end
  end
end

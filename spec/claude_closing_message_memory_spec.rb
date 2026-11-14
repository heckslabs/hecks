# frozen_string_literal: true

require "spec_helper"
require_relative "support/plan_page_speed_kit"
require_relative "../lib/hecks/hecks/adapters/claude_closing_message"

# A finished session's transcript is parsed once, however many pages ask for its closing message.
RSpec.describe Hecks::Adapters::ClaudeClosingMessage do
  include PlanPageSpeedKit

  let(:projects) { projects_with_transcript }

  after { FileUtils.rm_rf(projects) }

  it "parses a finished session's transcript once" do
    closing = described_class.new(projects: projects)
    allow(JSON).to receive(:parse).and_call_original
    2.times { closing.of("abc123") }
    expect(JSON).to have_received(:parse).once
  end

  it "answers the same text from a second reader" do
    2.times { described_class.new(projects: projects).of("abc123") }
    expect(described_class.new(projects: projects).of("abc123")).to eq("Verdict: sound")
  end

  it "does not search the project folders again for a session it found no transcript for" do
    closing = described_class.new(projects: projects)
    allow(Dir).to receive(:glob).and_call_original
    3.times { closing.of("no-such-session") }
    expect(Dir).to have_received(:glob).once
  end

  describe "what the shared memory keeps" do
    let(:memory) { described_class::MEMORY }

    def ask_for(count, closing)
      count.times { |n| closing.of("gone-#{n}") }
    end

    it "holds a search that found nothing only until it may be made again", :aggregate_failures do
      stub_const("#{described_class}::MISS_SECONDS", 0)
      closing = described_class.new(projects: projects)
      before = memory[:misses].size
      ask_for(25, closing)
      expect(memory[:misses].size - before).to be <= 1
    end

    it "holds no more transcripts than its bound however many sessions are asked for" do
      stub_const("#{described_class}::KEPT", 2)
      closing = described_class.new(projects: projects)
      6.times { |n| File.write(File.join(projects, "p", "s#{n}.jsonl"), "{}\n") }
      6.times { |n| closing.of("s#{n}") }
      expect(memory[:texts].size).to be <= 2
    end

    it "holds no more found paths than its bound" do
      stub_const("#{described_class}::KEPT", 2)
      closing = described_class.new(projects: projects)
      6.times { |n| File.write(File.join(projects, "p", "t#{n}.jsonl"), "{}\n") }
      6.times { |n| closing.of("t#{n}") }
      expect(memory[:paths].size).to be <= 2
    end
  end
end

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
end

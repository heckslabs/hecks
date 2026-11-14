# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "hecks/pipeline_board/adapters/pipeline_web"

# A read that cannot finish within its bound is skipped, not retried: the section shows its last
# answer with the time that answer was read, and the reader is asked once a refresh at most.
RSpec.describe Hecks::Adapters::PipelineBoard::Stale do
  let(:host) do
    Class.new do
      include Hecks::Adapters::PipelineBoard::Gather

      def initialize(github)
        @read_seconds = 0.2
        @github = github
        %i[git tickets jobs fill journal disk].each { |name| instance_variable_set("@#{name}", Object.new) }
      end

      public :gathered
    end
  end
  let(:gate) { Queue.new }
  let(:asked) { [] }

  # A GitHub reader that answers its first read and never its second.
  def github
    calls = asked
    slow = gate
    Object.new.tap do |reader|
      reader.define_singleton_method(:latest_release) { (calls << :release).size == 1 ? { tag: "v1" } : slow.pop }
    end
  end

  def after_a_slow_read
    host.new(github).tap { |gathering| 2.times { gathering.gathered } }
  end

  it "shows the last answer when a read misses its bound" do
    gathering = host.new(github)
    expect(Array.new(2) { gathering.gathered[:release] }).to eq([{ tag: "v1" }, { tag: "v1" }])
  end

  it "says since when the answer is stale, and why", :aggregate_failures do
    note = after_a_slow_read.stale_sections[:release]
    expect(note[:reason]).to eq("reader did not answer in 0.2s")
    expect(Time.iso8601(note[:since])).to be_within(5).of(Time.now)
  end

  it "does not ask a timed-out reader a second time in the same refresh" do
    after_a_slow_read
    expect(asked.size).to eq(2)
  end

  it "does not ask it again while that read is still running", :aggregate_failures do
    gathering = after_a_slow_read.tap(&:gathered)
    expect(asked.size).to eq(2)
    expect(gathering.stale_sections[:release][:reason]).to eq("the last read is still running")
  end

  it "notes nothing for a section that answered" do
    expect(host.new(github).tap(&:gathered).stale_sections).not_to have_key(:release)
  end

  it "keeps unknown for a section that never answered" do
    expect(host.new(github).gathered[:ci_runs]).to include(:unknown)
  end
end

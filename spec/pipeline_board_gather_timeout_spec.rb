# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"

# One reader that never answers is given as unknown after its time, and the others still answer.
RSpec.describe Hecks::Adapters::PipelineBoard::Gather do
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

  def stuck_github
    gate = Queue.new
    github = Object.new
    github.define_singleton_method(:ci_runs) { |*| gate.pop }
    github.define_singleton_method(:latest_release) { { tag: "v1" } }
    github
  end

  it "answers a slow reader as unknown" do
    expect(host.new(stuck_github).gathered[:ci_runs]).to eq(unknown: "reader did not answer in 0.2s")
  end

  it "does not ask a reader again while its last read is still running", :aggregate_failures do
    github = stuck_github
    allow(github).to receive(:ci_runs).and_call_original
    gathering = host.new(github).tap { |twice| 2.times { twice.gathered } }
    expect(github).to have_received(:ci_runs).once
    expect(gathering.gathered[:ci_runs]).to eq(unknown: "the last read is still running")
  end

  it "still answers the readers that were not slow" do
    expect(host.new(stuck_github).gathered[:release]).to eq(tag: "v1")
  end
end

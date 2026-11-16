# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"

# The board and the reader that never answers, as the gather specs build them.
module GatherTimeoutSpecWorld
  def host_class
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
end

# One reader that never answers is given as unknown after its time, and the others still answer.
RSpec.describe Hecks::Adapters::PipelineBoard::Gather do
  include GatherTimeoutSpecWorld

  let(:host) { host_class }

  it "answers a slow reader as unknown" do
    expect(host.new(stuck_github).gathered[:ci_runs]).to eq(unknown: "reader did not answer in 0.2s")
  end

  it "logs where an overdue reader is, on one line" do
    expect { host.new(stuck_github).gathered }.to output(/\Aboard: ci_runs reader overdue after 0.2s at [^\n]+\n\z/).to_stderr
  end

  it "names an overdue section once for the window, not on every read" do
    board = host.new(stuck_github)
    board.gathered
    expect { board.gathered }.not_to output.to_stderr
  end

  it "still answers the readers that were not slow" do
    expect(host.new(stuck_github).gathered[:release]).to eq(tag: "v1")
  end
end

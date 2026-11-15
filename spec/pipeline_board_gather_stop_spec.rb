# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_web"

# A reader past its time is stopped, so a reader wedged outside any command cannot hold its section
# for good; one inside a call that cannot be interrupted stays on record and is not asked twice.
RSpec.describe Hecks::Adapters::PipelineBoard::Gather, "stopping a reader" do
  let(:host) do
    Class.new do
      include Hecks::Adapters::PipelineBoard::Gather

      def initialize(github)
        @read_seconds = 0.1
        @github = github
        %i[git tickets jobs fill journal disk].each { |name| instance_variable_set("@#{name}", Object.new) }
      end

      public :gathered
    end
  end

  def github_that(&reading)
    Object.new.tap { |github| github.define_singleton_method(:ci_runs, &reading) }
  end

  it "stops a reader past its time, so the next refresh asks again", :aggregate_failures do
    github = github_that { |*| Queue.new.pop }
    allow(github).to receive(:ci_runs).and_call_original
    host.new(github).tap { |twice| 2.times { twice.gathered } }
    expect(github).to have_received(:ci_runs).twice
  end

  it "does not ask again while a reader that cannot be stopped is still running" do
    github = github_that { |*| Thread.handle_interrupt(Object => :never) { Queue.new.pop } }
    stuck = host.new(github).tap { |twice| 2.times { twice.gathered } }
    expect(stuck.gathered[:ci_runs]).to eq(unknown: "the last read is still running")
  end
end

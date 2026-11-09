# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"

# The store another checkout keeps, read in this process: booted once and kept, never by a launcher.
RSpec.describe Hecks::Adapters::PipelineBoard::LiveStore do
  let(:unavailable) { Hecks::Adapters::PipelineBoard::Unavailable }
  let(:boots) { [] }

  # Answers like a runtime's registry: one bluebook with one aggregate holding two records.
  def runtime
    aggregate = Struct.new(:hecks_name).new("AgentRun")
    bluebook = Struct.new(:aggregates).new([aggregate])
    registry = Class.new do
      define_method(:bluebook) { |_domain| bluebook }
      define_method(:repository) { |_domain, _aggregate| Struct.new(:all).new(%i[a b]) }
    end.new
    Struct.new(:registry).new(registry)
  end

  def store(booter = nil)
    booter ||= ->(directory) { runtime.tap { boots << directory } }
    described_class.new(root: "/live", booter: booter)
  end

  it "answers the records of an aggregate", :aggregate_failures do
    expect(store.records("Hecks", "AgentRun")).to eq(%i[a b])
    expect(boots).to eq(["/live/lib/hecks/hecks"])
  end

  it "boots the checkout once however often it is read" do
    reader = store
    3.times { reader.records("Hecks", "AgentRun") }
    expect(boots.size).to eq(1)
  end

  it "says when the checkout declares no such aggregate" do
    expect { store.records("Hecks", "Nope") }.to raise_error(unavailable, /declares no Hecks.Nope/)
  end

  it "says when the checkout will not open" do
    broken = store(->(_) { raise "no domain here" })
    expect { broken.records("Hecks", "AgentRun") }.to raise_error(unavailable, /did not open: no domain here/)
  end
end

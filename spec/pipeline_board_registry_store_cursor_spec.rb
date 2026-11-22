# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"
require_relative "support/registry_store_event_log_world"

# A board refresh reads the events a Work aggregate's log gained since the last refresh.
RSpec.describe Hecks::Adapters::PipelineBoard::RegistryStore do
  include RegistryStoreEventLogWorld

  let(:time) { [0.0] }
  let(:log) { RegistryStoreEventLog.new(:started, :finished) }
  let(:store) { store_over(log) }

  before { refresh(store, 0.0) }

  it "reads only the new event when one is recorded before the next refresh" do
    log.append(:landed)
    refresh(store, 6.0)
    expect(log.read_past.last).to eq(2)
  end

  it "answers the old events and the new one together" do
    log.append(:landed)
    expect(refresh(store, 6.0)).to eq(%i[started finished landed])
  end

  it "never loads the whole log on a refresh" do
    log.append(:landed)
    refresh(store, 6.0)
    expect(log.read_whole).to eq(0)
  end

  it "leaves an answer handed out earlier unchanged by the next refresh" do
    earlier = refresh(store, 0.0)
    log.append(:landed)
    refresh(store, 6.0)
    expect(earlier).to eq(%i[started finished])
  end

  it "reads the whole log again when the log holds fewer events than the cursor kept" do
    log.replace(:started)
    expect(refresh(store, 6.0)).to eq([:started])
  end

  it "reads the whole log again when the registry is another checkout's" do
    other = RegistryStoreEventLog.new(:started, :other)
    store.instance_variable_set(:@registry, registry_of(other))
    expect(refresh(store, 6.0)).to eq(%i[started other])
  end
end

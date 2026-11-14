require "spec_helper"
require "tmpdir"

# Boards the push train from a checkout that is not there, so the boarding faults, and reads what
# the GateAndBoard saga made of it. The Hecks domain boots in Memory.
module ShipmentStoppedHelpers
  SAGA = "GateAndBoard".freeze

  def absent = File.join(Dir.tmpdir, "hecks-shipment-stopped-absent", "checkout")

  def ship(run)
    hecks.dispatch("Hecks::Shipment.Ship", with: { run: { value: run }, branch: { value: "feature" },
                                                   checkout: { value: absent },
                                                   confirm: { value: true } })
    hecks.registry.saga_instances[SAGA][run][:state] = "boarding"
  end

  def board(run)
    hecks.dispatch("Hecks::SendTrain.Board", with: { run: { value: run }, checkout: { value: absent },
                                                     confirm: { value: true } })
  end

  def names = hecks.events.map(&:name)

  # The stage each ShipmentStopped event names.
  def stopped_stages
    hecks.events.select { |event| event.name == "ShipmentStopped" }.map do |event|
      stage = event.payload[:stage]
      stage.respond_to?(:value) ? stage.value : stage[:value]
    end
  end
end

# A shipment whose boarding faults parks in needs_human and records the park as Shipment.Stop,
# which Tickets files as a stopped run; a boarding that faults outside a shipment records no park.
RSpec.describe "a shipment that stops at boarding" do
  include ShipmentStoppedHelpers

  let(:hecks) { boot_hecks_in_memory }

  it "parks the shipment's saga in needs_human" do
    ship("parked")
    board("parked")
    expect(hecks.registry.saga_instances[ShipmentStoppedHelpers::SAGA]["parked"][:state]).to eq("needs_human")
  end

  it "records the park with its stage and the boarding's reason", :aggregate_failures do
    ship("parked")
    board("parked")
    expect(stopped_stages).to eq(["boarding"])
    expect(names).to include("StoppedRunReported")
  end

  it "records no park for a boarding outside a shipment", :aggregate_failures do
    board("bare")
    expect(names).to include("PushFaulted")
    expect(names).not_to include("ShipmentStopped", "StoppedRunReported")
  end
end

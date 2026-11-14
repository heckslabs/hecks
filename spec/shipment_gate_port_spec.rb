require "spec_helper"
require_relative "support/stand_in_checkout"

# Ships a branch whose checkout is a stand-in with a launcher of its own, and reads where the
# GateAndBoard saga stands once the Gate port has answered. The Hecks domain boots in Memory.
RSpec.describe "a shipment judged by its checkout's gate" do
  include StandInCheckout

  let(:hecks) { boot_hecks_in_memory }

  def ship(run, directory)
    hecks.dispatch("Hecks::Shipment.Ship", with: { run: { value: run }, branch: { value: "feature" },
                                                   checkout: { value: directory }, confirm: { value: true } })
  end

  def state(run) = hecks.registry.saga_instances["GateAndBoard"][run][:state]

  def names = hecks.events.map(&:name)

  # Mends the stand-in checkout and asks for its gate again.
  def mend_and_rejudge(run, directory)
    write_launcher(directory, :green)
    hecks.dispatch("Hecks::Shipment.Rejudge", to: run, with: {})
  end

  it "moves to landing when the gate is green", :aggregate_failures do
    in_checkout(gate: :green) do |directory|
      ship("green", directory)
      expect(names).to include("JudgementAnswered")
      expect(state("green")).to eq("landing")
    end
  end

  it "parks in needs_human when the gate is red", :aggregate_failures do
    in_checkout(gate: :red) do |directory|
      ship("red", directory)
      expect(names).to include("JudgementRefused")
      expect(state("red")).to eq("needs_human")
    end
  end

  it "moves on from needs_human when the mended checkout is judged again" do
    in_checkout(gate: :red) do |directory|
      ship("mended", directory)
      mend_and_rejudge("mended", directory)
      expect(state("mended")).to eq("landing")
    end
  end

  # What `hecks resume <run>` does, run in this process against the booted domain.
  def resume(run)
    scope = { runtime: hecks, bluebook: hecks.registry.bluebook("Hecks"), program: "hecks" }
    Object.new.extend(Hecks::Adapters::Driving::CliRunner::ResumeWords).resume(scope, ["resume", run])
  end

  # Ships into a red gate, mends the checkout and resumes; answers the resume's exit status.
  def resumed_after_mending(run, directory)
    ship(run, directory)
    write_launcher(directory, :green)
    resume(run)[:answer].last
  end

  it "is judged again by a resume, with the arguments the shipment started with", :aggregate_failures do
    in_checkout(gate: :red) do |directory|
      expect(resumed_after_mending("resumed", directory)).to eq(0)
      expect(state("resumed")).to eq("landing")
    end
  end

  it "names no check of this repository in the saga" do
    saga = hecks.registry.bluebook("Hecks").process_managers.find { |manager| manager.name == "GateAndBoard" }
    heard = saga.handlers.map { |handler| handler.event_type.to_s } + saga.resumes
    expect(heard.grep(/StyleRun|ConformanceRun|GateRun/)).to be_empty
  end
end

require "spec_helper"
require_relative "../support/booted_source"

# `Dispatcher#validate`: the dry run, answering every reason a command would be refused as data.
RSpec.describe Hecks::Runtime::Dispatcher, "#validate" do
  PLUMBED_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Plumbed" do
      aggregate "Valve" do
        identified_by :tag
        attribute :tag,  Tag
        attribute :flow, Flow
        attribute :size, Size
        value_object("Tag")  { attribute :value, String }
        value_object("Flow") { attribute :value, Integer }
        value_object("Size") { attribute :value, Integer }
        lifecycle :status, default: "shut" do
          transition "Open" => "open", from: "shut"
        end
        command("Fit") do
          attribute :tag,  Tag
          attribute :flow, Flow
          attribute :size, Size
          given("the flow is positive") { flow.value > 0 }
          given("the size is positive") { size.value > 0 }
          sets :tag
          sets :flow
          sets :size
          emits "ValveFitted"
        end
        command("Open", from: "shut") do
          reference_to Valve
          emits "ValveOpened"
        end
      end
    end
  BLUEBOOK

  let(:dispatcher) do
    BootedSource.boot(PLUMBED_SOURCE) { Hecks.hecksagon("Plumbed") { Plumbed::Valve.persisted_by("Memory") } }
  end

  def validating_fit(tag: { value: "v1" }, flow: { value: 3 }, size: { value: 2 }, **more)
    dispatcher.validate("Plumbed::Valve.Fit", tag: tag, flow: flow, size: size, **more)
  end

  def stored = dispatcher.registry.repository("Plumbed", dispatcher.registry.bluebook("Plumbed").aggregate("Valve")).all

  def raised(verb, **args)
    dispatcher.dry_run?(verb, **args)
    nil
  rescue Hecks::Refused => e
    e
  end

  it "accepts a command that would pass", :aggregate_failures do
    expect(validating_fit).to be_ok
    expect(validating_fit.to_h).to eq(ok: true, refusals: [])
  end

  it "saves and emits nothing" do
    validating_fit

    expect([stored, dispatcher.events]).to all(be_empty)
  end

  it "reports every given that does not hold, naming each rule", :aggregate_failures do
    result = validating_fit(flow: { value: 0 }, size: { value: 0 })

    expect(result.refusals.map(&:rule)).to eq(["the flow is positive", "the size is positive"])
    expect(result.refusals.map(&:stage).uniq).to eq([:givens])
  end

  it "reports every unknown and absent argument against its own attribute", :aggregate_failures do
    result = dispatcher.validate("Plumbed::Valve.Fit", tag: { value: "v1" }, bogus: 1)

    expect(result.refusals.map(&:attribute)).to eq(%i[bogus flow size])
    expect(result.refusals.map(&:stage).uniq).to eq([:arguments])
  end

  it "reports every argument of the wrong type", :aggregate_failures do
    result = validating_fit(flow: { value: "x" }, size: { value: "y" })

    expect(result.refusals.map(&:path)).to eq(%w[/flow/value /size/value])
    expect(result.refusals.map(&:attribute)).to eq(%i[flow size])
  end

  it "stops after a stage that refused, since a later stage would read what it never settled" do
    result = validating_fit(flow: { value: "x" }, size: { value: 0 })

    expect(result.refusals.map(&:stage).uniq).to eq([:arguments])
  end

  it "names a verb that is not declared" do
    result = dispatcher.validate("Plumbed::Valve.Bolt")

    expect(result.refusals.map(&:stage)).to eq([:request])
  end

  it "refuses a lifecycle move the record's state does not allow", :aggregate_failures do
    dispatcher.dispatch_flat("Plumbed::Valve.Fit", tag: { value: "v1" }, flow: { value: 3 }, size: { value: 2 })
    dispatcher.dispatch_flat("Plumbed::Valve.Open", tag: "v1")

    expect(dispatcher.validate("Plumbed::Valve.Open", tag: "v1").refusals.map(&:stage)).to eq([:state])
  end

  def agrees?(more)
    result = validating_fit(**more)
    refusal = raised("Plumbed::Valve.Fit", tag: { value: "v1" }, flow: { value: 3 }, size: { value: 2 }, **more)
    result.ok? == refusal.nil? && result.refusals.first&.message == refusal&.message
  end

  it "agrees with the dry run on whether a command is accepted, and on the first reason" do
    inputs = [{}, { flow: { value: 0 } }, { size: { value: "y" } }, { bogus: 1 }]

    expect(inputs.reject { |more| agrees?(more) }).to be_empty
  end

  def agrees_on_facts?(more)
    facts = { tag: { value: "v1" }, flow: { value: 3 }, size: { value: 2 }, **more }
    result = dispatcher.validate_facts("Plumbed::Valve.Fit", **facts)
    refusal = raised("Plumbed::Valve.Fit", **facts)
    result.ok? == refusal.nil? && result.refusals.first&.message == refusal&.message
  end

  it "asks of to and with as facts through validate_facts, the question dry_run? is asked" do
    inputs = [{ with: nil }, { with: { flow: { value: 1 } } }, { to: "v1" }, { flow: { value: 0 } }]

    expect(inputs.reject { |more| agrees_on_facts?(more) }).to be_empty
  end

  it "leaves dry_run? raising its first refusal" do
    expect { dispatcher.dry_run?("Plumbed::Valve.Fit", tag: { value: "v1" }, bogus: 1) }
      .to raise_error(Hecks::Runtime::UnknownArgument)
  end
end

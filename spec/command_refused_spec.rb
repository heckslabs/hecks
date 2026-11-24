require "spec_helper"

# A command the domain refuses leaves a CommandRefused fact, so a policy can answer a no; the
# refusal itself reaches the caller unchanged.
RSpec.describe "a refused command" do
  let(:hecks) { Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/framework"), install_driving: false) }
  let(:blank) do
    { message: { value: "m1" }, sender: { value: "baker" }, recipient: { value: "driver" },
      kind: { value: "question" }, body: { value: " " } }
  end

  def send_blank = hecks.dispatch_flat("Messaging::Message.Send", **blank)

  def refused = hecks.events.select { |event| event.name.to_s == "CommandRefused" }

  it "raises the same refusal the caller always saw" do
    expect { send_blank }.to raise_error(Hecks::Runtime::GivenNotMet, /says something/)
  end

  it "emits CommandRefused naming the command, the rule and the argument names", :aggregate_failures do
    expect { send_blank }.to raise_error(Hecks::Refused)
    payload = refused.first.payload
    expect(payload[:command].value).to include("Messaging::Message.Send")
    expect(payload[:given].value).to include("says something")
    expect(payload[:arguments].value).to include("body")
  end

  it "never carries an argument's value", :aggregate_failures do
    expect { hecks.dispatch_flat("Messaging::Message.Send", **blank, body: { value: "s3cret " * 400 }) }
      .to raise_error(Hecks::Refused)
    expect(refused.first.payload.values.map(&:value).join).not_to include("s3cret")
  end

  it "records nothing for a dry run" do
    expect { hecks.dry_run?("Messaging::Message.Send", **blank) }.to raise_error(Hecks::Refused)
    expect(refused).to be_empty
  end

  it "records a refused Record no further" do
    expect { hecks.dispatch_flat("Refusal::CommandRefusal.Record", refusal: { value: "r" }, command: { value: "" }, given: { value: "x" }) }
      .to raise_error(Hecks::Refused)
    expect(refused).to be_empty
  end
end

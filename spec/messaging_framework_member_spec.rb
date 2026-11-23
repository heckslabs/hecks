require "spec_helper"

# Messaging is a framework member any app attaches: a message has a kind and a channel the member
# declares, hangs on whatever carries it (a Work item, an order), is heard once and then read.
RSpec.describe "messaging" do
  let(:hecks) { Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/framework"), install_driving: false) }
  let(:says) do
    { message: { value: "m1" }, sender: { value: "baker" }, recipient: { value: "driver" },
      kind: { value: "question" }, body: { value: "Is order 7 out?" } }
  end

  def send_message(**over) = hecks.dispatch_flat("Messaging::Message.Send", **says, **over)

  def inbox = hecks.query("Messaging::Message.Inbox", recipient: { value: "driver" })

  it "is a framework member" do
    expect(Hecks::Framework.members).to include("Messaging")
  end

  it "keeps a sent message in its recipient's inbox" do
    send_message

    expect(inbox.map { |row| row[:message] }).to eq([{ value: "m1" }])
  end

  it "hangs a message on the order that carries it" do
    send_message(subject_kind: { value: "Order" }, subject_ref: { value: "order-7" })

    expect(hecks.query("Messaging::Message.All").first[:subject_ref]).to eq({ value: "order-7" })
  end

  it "refuses a kind it does not declare" do
    expect { send_message(kind: { value: "gossip" }) }.to raise_error(/MessageKind admits/)
  end

  it "takes a message out of the inbox once it is read", :aggregate_failures do
    send_message
    hecks.dispatch_flat("Messaging::Message.Receive", message: { value: "m1" }, reader: { value: "driver" })
    hecks.dispatch_flat("Messaging::Message.Read", message: { value: "m1" }, reader: { value: "driver" })

    expect(inbox).to be_empty
    expect(hecks.query("Messaging::Message.All").first[:status]).to eq("read")
  end

  it "announces an event as a message on a channel" do
    hecks.dispatch_flat("Messaging::Message.Announce", **says, kind: { value: "report" }, channel: { value: "train" })

    expect(hecks.query("Messaging::Message.All").first[:channel]).to eq({ value: "train" })
  end
end

# frozen_string_literal: true

require "hecks/agents/adapters/slack_post"

RSpec.describe Hecks::Adapters::SlackPost do
  subject(:post) do
    described_class.new(owner: "UOWNER", channel: "CCREW", agents: %w[scrum-master lead],
                        names: { "UDANA" => "Dana" }.method(:fetch))
  end

  def event(user:, text:, **more)
    { "channel" => "CCREW", "user" => user, "text" => text, "client_msg_id" => "id1" }.merge(more)
  end

  it "sends the owner's unaddressed post to the orchestrator as the owner" do
    expect(post.line(event(user: "UOWNER", text: "status?")))
      .to include(recipient: "orchestrator", sender: "owner", kind: "owner", body: "status?")
  end

  it "sends another person's post under their own name with the person kind" do
    expect(post.line(event(user: "UDANA", text: "hello")))
      .to include(recipient: "orchestrator", sender: "Dana", kind: "person")
  end

  it "addresses a known agent by a name: prefix and strips it" do
    expect(post.line(event(user: "UDANA", text: "Scrum-Master: file this")))
      .to include(recipient: "scrum-master", body: "file this")
  end

  it "sends a post that names no known agent whole to the orchestrator" do
    expect(post.line(event(user: "UDANA", text: "note: later")))
      .to include(recipient: "orchestrator", body: "note: later")
  end

  it "keys the message by the Slack message id" do
    expect(post.line(event(user: "UDANA", text: "hi"))).to include(message: "slack-id1")
  end

  it "ignores another channel, a bot's post and an edit" do
    posts = [event(user: "UDANA", text: "x", "channel" => "COTHER"),
             event(user: "UDANA", text: "x", "bot_id" => "B1"),
             event(user: "UDANA", text: "x", "subtype" => "message_changed")]
    expect(posts.map { |each| post.line(each) }).to all(be_nil)
  end

  it "keeps a long post under the body and line limits" do
    line = post.line(event(user: "UDANA", text: "é" * 3000))
    expect(JSON.generate(line).bytesize).to be <= 4000
  end
end

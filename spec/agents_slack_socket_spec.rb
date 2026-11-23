# frozen_string_literal: true

require "stringio"
require "hecks/agents/adapters/slack_socket"

RSpec.describe Hecks::Adapters::SlackSocket do
  def text_frame(text) = [0x81, text.bytesize].pack("CC") + text

  def duplex(bytes)
    Struct.new(:incoming, :written) do
      def read(count) = incoming.read(count)
      def write(data) = written.write(data)
    end.new(StringIO.new(bytes), StringIO.new)
  end

  it "reads a text frame, answers a ping and ends at a close" do
    socket = described_class.new(duplex([0x89, 0].pack("CC") + text_frame("hello") + [0x88, 0].pack("CC")))
    expect([socket.read, socket.read]).to eq(["hello", nil])
  end

  it "writes a masked text frame" do
    io = StringIO.new
    described_class.new(io).write("ack")
    expect(io.string.getbyte(1)).to eq(0x80 | 3)
  end
end

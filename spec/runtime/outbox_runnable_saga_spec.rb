require "spec_helper"

# A pending saga row is not a policy ask, so a process with no adapter still leaves it to the relay
# to run, instead of failing on `false.asks?`.
RSpec.describe Hecks::Runtime::Outbox::Runnable do
  let(:relay) do
    Class.new do
      include Hecks::Runtime::Outbox::Runnable

      def initialize = (@registry = Object.new)

      def reason(row) = unrunnable_reason(row)
    end.new
  end

  it "has no reason to withhold a saga row" do
    row = Struct.new(:consumer).new("saga:Shop::Checkout")
    expect(relay.reason(row)).to be_nil
  end
end

require "spec_helper"

RSpec.describe Hecks::Command::Dispatch do
  it "is included automatically when a class includes Hecks::Command" do
    klass = Class.new do
      include Hecks::Command
      def call; end
    end
    expect(klass.ancestors).to include(Hecks::Command::Dispatch)
  end

  it "provides private build_events method on instances" do
    klass = Class.new do
      include Hecks::Command
      def call; end
    end
    instance = klass.new
    expect(instance.private_methods).to include(:build_events)
  end

  it "provides private persist_aggregate method on instances" do
    klass = Class.new do
      include Hecks::Command
      def call; end
    end
    instance = klass.new
    expect(instance.private_methods).to include(:persist_aggregate)
  end
end

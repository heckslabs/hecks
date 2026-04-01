require "spec_helper"

RSpec.describe Hecks::Command::Validation do
  it "is included automatically when a class includes Hecks::Command" do
    klass = Class.new do
      include Hecks::Command
      def call; end
    end
    expect(klass.ancestors).to include(Hecks::Command::Validation)
  end

  it "provides preconditions DSL at class level" do
    klass = Class.new do
      include Hecks::Command
      precondition("must be true") { true }
      def call; end
    end
    expect(klass.preconditions.size).to eq(1)
    expect(klass.preconditions.first.message).to eq("must be true")
  end

  it "provides postconditions DSL at class level" do
    klass = Class.new do
      include Hecks::Command
      postcondition("after check") { |_before, _after| true }
      def call; end
    end
    expect(klass.postconditions.size).to eq(1)
    expect(klass.postconditions.first.message).to eq("after check")
  end
end

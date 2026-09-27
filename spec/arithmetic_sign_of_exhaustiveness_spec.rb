require "spec_helper"

# Pins `sign_of` refusing an unknown op and a signless op (set/append/...) instead of
# defaulting to decrement's -1. Callers gate non-arithmetic ops first, so this tests the backstop.
RSpec.describe "CommandRules::Arithmetic#sign_of" do
  def rules = Hecks::Runtime::CommandRules.new(nil)

  it "answers the declared sign for increment and decrement" do
    expect(rules.sign_of(:increment)).to eq(1)
    expect(rules.sign_of(:decrement)).to eq(-1)
  end

  it "refuses a declared op that carries no sign, rather than silently answering decrement" do
    expect { rules.sign_of(:set) }
      .to raise_error(Hecks::Runtime::WiringError, /no sign declared for mutation op :set/)
  end

  it "refuses an op name the table has never heard of at all" do
    expect { rules.sign_of(:teleport) }
      .to raise_error(Hecks::Runtime::WiringError, /no sign declared for mutation op :teleport/)
  end
end

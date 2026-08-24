require "spec_helper"

# `Arithmetic#sign_of` used to answer DECREMENT's sign for both an unknown
# op name and a declared, real op that carries no sign at all (set/append/
# multiply/clamp/remove) — `.find(...)&.sign || -1` can't tell "not found"
# from "found, sign legitimately nil" apart from "found, sign is -1". Both
# callers already gate every non-arithmetic op through their own `case`
# before reaching #sign_of, so this is a direct, no-boot unit test of the
# backstop itself, not a real dispatch path today.
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

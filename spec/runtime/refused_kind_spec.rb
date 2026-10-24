require "spec_helper"

# A driving adapter answers a missing record or a missing role differently from a rule that did not
# hold, and reads the difference from `#kind` without naming the runtime's classes.
RSpec.describe Hecks::Refused, "#kind" do
  it "is :refused for a rule that did not hold" do
    expect(Hecks::Runtime::GivenNotMet.new("no").kind).to eq(:refused)
  end

  it "names a missing record" do
    expect(Hecks::Runtime::NotFound.new("gone").kind).to eq(:not_found)
  end

  it "names a caller who lacks the role" do
    expect(Hecks::Runtime::Unauthorized.new("no role").kind).to eq(:unauthorized)
  end

  it "names an argument the call left out" do
    expect(Hecks::Runtime::AbsentArgument.new("missing").kind).to eq(:absent_argument)
  end
end

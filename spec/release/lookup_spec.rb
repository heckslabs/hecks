require "spec_helper"
require "hecks/release/lookup"

# A release lookup that errors is not a release that is missing: only GitHub saying "release not
# found" is absence, and any other answer is a failed lookup that is retried and then named.
RSpec.describe Hecks::Release::Lookup do
  let(:out) { StringIO.new }
  let(:no_wait) { ->(_seconds) {} }

  def answering(*answers) = answers.each_with_object([]) { |a, list| list << a }.then { |list| ->(_tag) { list.shift || list.last } }

  def check(*answers) = described_class.check("v7.1.0", runner: answering(*answers), out: out, sleeper: no_wait)

  it "reads a published release as found" do
    expect(check([0, "title: v7.1.0"])).to eq(0)
  end

  it "reads GitHub's 'release not found' as no release" do
    expect(check([1, "release not found"])).to eq(1)
  end

  it "reads a rate limit as a failed lookup, never as no release", :aggregate_failures do
    expect(check([1, "HTTP 403: API rate limit exceeded"])).to eq(2)
    expect(out.string).to include("::error::release lookup failed")
  end

  it "retries a failed lookup and takes the answer that follows" do
    expect(check([1, "HTTP 502"], [0, "ok"])).to eq(0)
  end

  it "ends 'lookup failed' when every attempt fails", :aggregate_failures do
    expect(check([1, "HTTP 403: API rate limit exceeded"])).to eq(2)
    expect(out.string).to include("v7.1.0")
  end
end

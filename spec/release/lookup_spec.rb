require "spec_helper"
require "hecks/release/lookup"

# A release lookup that errors is not a release that is missing: only GitHub saying "release not
# found" is absence, and any other answer is a failed lookup that is retried and then named.
RSpec.describe Hecks::Release::Lookup do
  let(:out) { StringIO.new }
  let(:no_wait) { ->(_seconds) {} }

  def answering(*answers) = ->(_tag) { answers.size > 1 ? answers.shift : answers.first }

  def check(*answers) = described_class.check("v7.1.0", runner: answering(*answers), out: out, sleeper: no_wait)

  it "reads a published release as found" do
    expect(check([0, "title: v7.1.0"])).to eq(0)
  end

  it "reads GitHub's 'release not found' as no release" do
    expect(check([1, "release not found"])).to eq(described_class::MISSING)
  end

  it "keeps 'no release' apart from 1, the status a crashed Ruby exits with" do
    expect(described_class::MISSING).to eq(10)
  end

  it "reads a runner that raises (gh absent) as a failed lookup", :aggregate_failures do
    broken = ->(_tag) { raise Errno::ENOENT, "gh" }

    expect(described_class.check("v7.1.0", runner: broken, out: out, sleeper: no_wait)).to eq(2)
    expect(out.string).to include("::error::release lookup failed")
  end

  it "exits with a status other than 'no release' when the helper cannot be loaded" do
    lib = File.expand_path("../../lib", __dir__)
    system("ruby", "-I", lib, "-r", "hecks/release/lookup_absent", "-e", "exit 10", err: File::NULL)

    expect(Process.last_status.exitstatus).not_to eq(described_class::MISSING)
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

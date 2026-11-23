require "spec_helper"
require "hecks/release/lookup"

# The release detect job asks GitHub whether a version is published. A lookup that errors is not
# an answer: it is told apart from a release that is not there, and never read as pending.
RSpec.describe Hecks::Release::Lookup do
  let(:found) { ["name: v7.1.0\n", 0] }
  let(:absent) { ["release not found\n", 1] }
  let(:limited) { ["HTTP 403: API rate limit exceeded\n", 1] }

  def asking(*answers) = ->(_tag) { answers.shift || answers.last }

  def look(*answers, attempts: 3)
    described_class.run("v7.1.0", runner: asking(*answers), sleeper: ->(_) {}, attempts: attempts)
  end

  it "finds a published release" do
    expect(look(found)).to eq(:found)
  end

  it "says a release is absent only when GitHub says it is not found" do
    expect(look(absent)).to eq(:absent)
  end

  it "ends 'lookup failed' when the lookup errors every time, never absent", :aggregate_failures do
    expect(look(limited)).to eq(:failed)
    expect(look(["", 1])).to eq(:failed)
  end

  it "retries a failed lookup and takes the answer it later gets", :aggregate_failures do
    expect(look(limited, found)).to eq(:found)
    expect(look(limited, absent)).to eq(:absent)
  end

  it "stops asking after its attempts" do
    asked = 0
    described_class.run("v1", runner: ->(_) { asked += 1 && limited }, sleeper: ->(_) {}, attempts: 3)

    expect(asked).to eq(3)
  end

  describe ".check" do
    def checked(answer, out) = described_class.check(env: { "TAG" => "v7.1.0" }, out: out, runner: ->(_) { answer }, sleeper: ->(_) {})

    it "exits 0 for found, 1 for absent, 2 for a failed lookup, naming the failure", :aggregate_failures do
      out = StringIO.new
      expect(checked(found, out)).to eq(0)
      expect(checked(absent, out)).to eq(1)
      expect(checked(limited, out)).to eq(2)
      expect(out.string).to include("::error::release lookup failed")
    end
  end
end

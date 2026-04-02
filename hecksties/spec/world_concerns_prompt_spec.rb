require "spec_helper"
require "stringio"
require "hecks_cli"

RSpec.describe Hecks::WorldConcernsPrompt do
  def prompt_with(input, tty: true)
    fake = StringIO.new(input)
    allow(fake).to receive(:tty?).and_return(tty)
    described_class.new(say_method: ->(*) {}, stdin: fake).run
  end

  it "returns empty result when stdin is not a tty" do
    result = prompt_with("1\nprivacy\n", tty: false)
    expect(result).to eq(concerns: [], extensions: [], stub: false)
  end

  it "choice 2 returns empty result" do
    result = prompt_with("2\n")
    expect(result).to eq(concerns: [], extensions: [], stub: false)
  end

  it "choice 3 sets stub: true" do
    result = prompt_with("3\n")
    expect(result).to eq(concerns: [], extensions: [], stub: true)
  end

  it "choice 1 maps goals to extensions and deduplicates" do
    result = prompt_with("1\nprivacy, consent\n")
    expect(result[:concerns]).to eq([:privacy, :consent])
    expect(result[:extensions]).to eq([:pii, :auth])
    expect(result[:stub]).to be false
  end

  it "choice 1 filters invalid goal names silently" do
    result = prompt_with("1\ntransparency bogus\n")
    expect(result[:concerns]).to eq([:transparency])
    expect(result[:extensions]).to eq([:audit])
  end

  it "deduplicates :auth when both consent and security are selected" do
    result = prompt_with("1\nconsent, security\n")
    expect(result[:concerns]).to eq([:consent, :security])
    expect(result[:extensions]).to eq([:auth])
  end

  it "maps all six goals correctly" do
    result = prompt_with("1\nprivacy, transparency, consent, security, equity, sustainability\n")
    expect(result[:concerns]).to eq([:privacy, :transparency, :consent, :security, :equity, :sustainability])
    expect(result[:extensions]).to contain_exactly(:pii, :audit, :auth, :tenancy, :rate_limit)
  end
end

# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/shell"

# What `Shell#capture` labels a program's output, whatever locale the caller runs under: a
# launchd job has none, and Ruby then reads a pipe as `US-ASCII`.
RSpec.describe Hecks::Adapters::Shell, "#capture" do
  subject(:shell) { described_class.new }

  # Runs the block under the encodings a launchd child without a locale has: `US-ASCII` outside and
  # no internal encoding. Puts both back after.
  def without_a_locale
    before = [Encoding.default_external, Encoding.default_internal]
    Encoding.default_external = Encoding::US_ASCII
    Encoding.default_internal = nil
    yield
  ensure
    Encoding.default_external, Encoding.default_internal = before
  end

  it "labels a program's UTF-8 output UTF-8 when the caller has no locale", :aggregate_failures do
    out = without_a_locale { shell.capture("printf", "backgrounded \\302\\267 stand-in-session").out }
    expect([out.encoding, out]).to eq([Encoding::UTF_8, "backgrounded \u00b7 stand-in-session"])
  end

  it "keeps output that is not UTF-8 as its exact bytes", :aggregate_failures do
    out = shell.capture("printf", "\\377\\376").out
    expect([out.encoding, out.bytes]).to eq([Encoding::BINARY, [255, 254]])
  end
end

# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/tools/value_object_shorthand"

# The rewrite of a bare value object block into the shorthand: only a block that wraps one plain
# `value` attribute changes; one that carries an invariant, a constraint or a comment stays a block.
RSpec.describe Hecks::Tools::ValueObjectShorthand do
  let(:root) { Dir.mktmpdir("shorthand") }

  after { FileUtils.rm_rf(root) }

  def bluebook(text)
    FileUtils.mkdir_p(File.join(root, "lib"))
    File.write(File.join(root, "lib", "a.bluebook"), text)
  end

  def shorten(write:) = described_class.shorten(["lib"], root: root, write: write)

  def source = File.read(File.join(root, "lib", "a.bluebook"))

  it "rewrites a bare block as the shorthand when told to write", :aggregate_failures do
    bluebook(%(  value_object "Verdict" do\n    attribute :value, String\n  end\n))
    expect(shorten(write: true)).to eq("lib/a.bluebook" => 1)
    expect(source).to eq(%(  value_object "Verdict", String\n))
  end

  it "only counts, and writes nothing, on a dry run", :aggregate_failures do
    text = %(  value_object "Verdict" do\n    attribute :value, String\n  end\n)
    bluebook(text)
    expect(shorten(write: false)).to eq("lib/a.bluebook" => 1)
    expect(source).to eq(text)
  end

  # Two blocks the shorthand cannot say: one with an invariant and a constraint, one with a comment.
  def kept_blocks
    <<~BLUEBOOK
      value_object "Named" do
        attribute :value, String, matches: :present
        invariant("a name") { !value.to_s.empty? }
      end
      value_object "Noted" do
        # why this is here
        attribute :value, String
      end
    BLUEBOOK
  end

  it "leaves a block with an invariant, a constraint or a comment alone", :aggregate_failures do
    bluebook(kept_blocks)
    expect(shorten(write: true)).to eq({})
    expect(source).to eq(kept_blocks)
  end
end

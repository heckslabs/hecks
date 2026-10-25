require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/behaviors"
require "hecks/composer"
require_relative "support/hecks_parse_binary"

# docs/sentence-form.md is for people who will copy from it, so what it shows has to be true: the
# domain reads and is already in the wording the formatter writes, its examples run and pass, and
# its policies are the ones the Orders fixture checks against Ruby.
RSpec.describe "the guide to writing a domain in sentences", :io do
  include_context "with the hecks-parse binary"

  GUIDE = File.expand_path("../docs/sentence-form.md", __dir__)
  GUIDE_BLOCKS = File.read(GUIDE).scan(/```\n(.*?)```/m).flatten.freeze

  def block_starting(text) = GUIDE_BLOCKS.find { |block| block.start_with?(text) }

  def in_scratch_directory
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "page.bluebook"), block_starting("Domain:"))
      File.write(File.join(dir, "page.examples"), block_starting("Examples for:"))
      yield dir
    end
  end

  it "shows a domain, examples and policies" do
    expect([block_starting("Domain:"), block_starting("Examples for:"), block_starting("Policy:")]).to all(be_a(String))
  end

  it "writes its domain in the wording the formatter writes" do
    in_scratch_directory do |dir|
      out, err, status = Open3.capture3(Hecks::SentenceForm.binary, "format", "--chapter", "Cms", File.join(dir, "page.bluebook"))

      expect(status).to be_success, err
      expect(out).to eq(block_starting("Domain:"))
    end
  end

  it "runs its examples, and every one passes" do
    in_scratch_directory do |dir|
      result = Hecks::Behaviors.run(File.join(dir, "page.examples"))

      expect(result.parse_error).to be_nil
      expect(result.runs).not_to be_empty
      expect(result.runs.map(&:status)).to all(eq(:pass)), result.runs.map(&:message).compact.inspect
    end
  end

  it "shows policies that stand, word for word, in the Orders fixture" do
    orders = File.read(File.expand_path("fixtures/sentence/orders/sentence_form.bluebook", __dir__))

    expect(orders).to include(block_starting("Policy:").strip)
  end
end

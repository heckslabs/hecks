require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/behaviors"
require "hecks/composer"
require_relative "support/hecks_parse_binary"

# docs/sentence-form.md is for people who will copy from it, so what it shows has to be true: every
# domain it shows reads and is already in the wording the formatter writes, its examples run and
# pass, and its policies are the ones the Orders fixture checks against Ruby.
RSpec.describe "the guide to writing a domain in sentences", :io do
  include_context "with the hecks-parse binary"

  GUIDE = File.expand_path("../docs/sentence-form.md", __dir__)
  GUIDE_BLOCKS = File.read(GUIDE).scan(/```\n(.*?)```/m).flatten.freeze

  let(:scratch) { Dir.mktmpdir }

  after { FileUtils.remove_entry(scratch) }

  def block_starting(text) = GUIDE_BLOCKS.find { |block| block.start_with?(text) }

  def domain_blocks = GUIDE_BLOCKS.select { |block| block.start_with?("Domain:") }

  # Writes `text` as `name` in the scratch directory and answers its path.
  def write_file(name, text)
    path = File.join(scratch, name)
    File.write(path, text)
    path
  end

  # What the formatter writes for a domain block shown in the guide.
  def formatted(block)
    path = write_file("shown.bluebook", block)
    out, err, status = Open3.capture3(Hecks::SentenceForm.binary, "format", "--chapter", block[/\ADomain: (\w+)/, 1], path)
    raise err unless status.success?

    out
  end

  # The result of running the guide's examples beside its Page domain.
  def examples_result
    write_file("page.bluebook", block_starting("Domain:"))
    Hecks::Behaviors.run(write_file("page.examples", block_starting("Examples for:")))
  end

  it "shows a domain, examples and policies" do
    expect([block_starting("Domain:"), block_starting("Examples for:"), block_starting("Policy:")]).to all(be_a(String))
  end

  it "shows every domain in the wording the formatter writes" do
    expect(domain_blocks.map { |block| formatted(block) }).to eq(domain_blocks)
  end

  it "shows examples that parse" do
    expect(examples_result.parse_error).to be_nil
  end

  it "shows examples that run" do
    expect(examples_result.runs).not_to be_empty
  end

  it "shows examples that all pass" do
    result = examples_result
    expect(result.runs.map(&:status)).to all(eq(:pass)), result.runs.map(&:message).compact.inspect
  end

  it "shows policies that stand, word for word, in the Orders fixture" do
    orders = File.read(File.expand_path("fixtures/sentence/orders/sentence_form.bluebook", __dir__))

    expect(orders).to include(block_starting("Policy:").strip)
  end
end

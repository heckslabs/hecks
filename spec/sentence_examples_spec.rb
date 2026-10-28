require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/behaviors"
require_relative "support/hecks_parse_binary"

# Examples written as sentences are run by the behaviors runner: the parser compiles them to
# `.behaviors` text against the domain they are about, and the runner dispatches them as the
# roles they name. A pass has to mean something, so a wrong expectation has to fail.
RSpec.describe "examples written as sentences", :io do
  include_context "with the hecks-parse binary"

  FIXTURE_DIR = File.expand_path("fixtures/sentence/cms_page", __dir__)
  PAGE_EXAMPLES = File.join(FIXTURE_DIR, "sentence_form.examples")
  ORDER_EXAMPLES = File.expand_path("fixtures/sentence/orders/sentence_form.examples", __dir__)
  PAGE_EXAMPLE_NAMES = ["A drafted page can be published",
                        "A page comes off the site and goes back on",
                        "A published page cannot be published again",
                        "Only an editor may take a page down (Sam)",
                        "Only an editor may take a page down (Morgan)"].freeze
  ORDER_EXAMPLE_NAMES = ["A customer places an order and sends it off for its credit check",
                         "A sales rep can send an order off for a customer",
                         "Only a customer or a sales rep can send an order off",
                         "An order that was already sent off cannot be sent again"].freeze

  let(:scratch) { Dir.mktmpdir }

  after { FileUtils.remove_entry(scratch) }

  # Runs the Page examples from the scratch directory, beside the Page bluebook, with `replace`
  # swapped for `with` in their text.
  def run_changed(replace = nil, with = nil)
    FileUtils.cp(File.join(FIXTURE_DIR, "sentence_form.bluebook"), File.join(scratch, "page.bluebook"))
    text = File.read(PAGE_EXAMPLES)
    File.write(File.join(scratch, "page.examples"), replace ? text.sub(replace, with) : text)
    Hecks::Behaviors.run(File.join(scratch, "page.examples"))
  end

  def statuses(result) = result.runs.to_h { |run| [run.description, run.status] }

  def failures(result) = result.runs.map(&:message).compact.inspect

  describe "the Page examples" do
    let(:page) { Hecks::Behaviors.run(PAGE_EXAMPLES) }

    it "parse" do
      expect(page.parse_error).to be_nil
    end

    it "run as the roles they name" do
      expect(page.runs.map(&:description)).to eq(PAGE_EXAMPLE_NAMES)
    end

    it "all pass" do
      expect(page.runs.map(&:status)).to all(eq(:pass)), failures(page)
    end
  end

  describe "a domain that asks the outside, booting the Memory hecksagon beside the examples" do
    let(:orders) { Hecks::Behaviors.run(ORDER_EXAMPLES) }

    it "parses" do
      expect(orders.parse_error).to be_nil
    end

    it "runs each example" do
      expect(orders.runs.map(&:description)).to eq(ORDER_EXAMPLE_NAMES)
    end

    it "passes every one" do
      expect(orders.runs.map(&:status)).to all(eq(:pass)), failures(orders)
    end
  end

  describe "an example whose expectation is wrong" do
    let(:wrong) { run_changed("Then the page is published\n  And PagePublished", "Then the page is draft\n  And PagePublished") }

    it "fails, so a pass means something" do
      expect(statuses(wrong)["A drafted page can be published"]).to eq(:fail)
    end

    it "leaves the other examples passing" do
      expect(statuses(wrong)["A page comes off the site and goes back on"]).to eq(:pass)
    end
  end

  describe "the role a step runs as" do
    let(:sam) { run_changed("Sam is a Viewer", "Sam is an Editor").runs.find { |run| run.description.end_with?("(Sam)") } }

    it "decides the outcome: a viewer is refused, and the same step by an editor is not" do
      expect(sam.status).to eq(:fail)
    end

    it "is named in the failure" do
      expect(sam.message).to include("expected refused")
    end
  end

  describe "an example the parser refuses" do
    let(:refused) { run_changed("Given Dana drafts", "Given Pat drafts") }

    it "runs nothing" do
      expect(refused.runs).to be_empty
    end

    it "is reported as a parse error naming its line and column" do
      expect(refused.parse_error).to match(/page\.examples:\d+:\d+: I don't know who 'Pat' is/)
    end
  end

  it "says so when no bluebook file stands beside the examples" do
    path = File.join(scratch, "orphan.examples")
    File.write(path, "Examples for: Cms\n")

    expect(Hecks::Behaviors.run(path).parse_error).to include("no .bluebook beside it declares Cms")
  end

  it "is found by a sweep of the directory, beside any .behaviors files", :aggregate_failures do
    run_changed
    sweep = Hecks::Behaviors.run_all(scratch)

    expect(sweep.files_swept).to eq(1)
    expect(sweep.summary).to include(passed: 5, failed: 0, errored: 0)
  end
end

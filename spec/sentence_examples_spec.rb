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

  # A scratch directory holding the Page chapter and an examples file named after it, whose text
  # is the fixture's with `change` applied.
  def with_examples(change = nil)
    Dir.mktmpdir do |dir|
      FileUtils.cp(File.join(FIXTURE_DIR, "sentence_form.bluebook"), File.join(dir, "page.bluebook"))
      text = File.read(PAGE_EXAMPLES)
      text = change.call(text) if change
      path = File.join(dir, "page.examples")
      File.write(path, text)
      yield dir, path
    end
  end

  it "runs the Page examples as the roles they name, and every one passes" do
    result = Hecks::Behaviors.run(PAGE_EXAMPLES)

    expect(result.parse_error).to be_nil
    expect(result.runs.map(&:description)).to eq(
      ["A drafted page can be published",
       "A page comes off the site and goes back on",
       "A published page cannot be published again",
       "Only an editor may take a page down (Sam)",
       "Only an editor may take a page down (Morgan)"]
    )
    expect(result.runs.map(&:status)).to all(eq(:pass)), result.runs.map(&:message).compact.inspect
  end

  it "runs a domain that asks the outside, booting the Memory hecksagon that stands beside the examples" do
    orders = File.expand_path("fixtures/sentence/orders/sentence_form.examples", __dir__)
    result = Hecks::Behaviors.run(orders)

    expect(result.parse_error).to be_nil
    expect(result.runs.map(&:description)).to eq(
      ["A customer places an order and sends it off for its credit check",
       "A sales rep can send an order off for a customer",
       "Only a customer or a sales rep can send an order off",
       "An order that was already sent off cannot be sent again"]
    )
    expect(result.runs.map(&:status)).to all(eq(:pass)), result.runs.map(&:message).compact.inspect
  end

  it "fails an example whose expectation is wrong, so a pass means something" do
    with_examples(->(text) { text.sub("Then the page is published\n  And PagePublished", "Then the page is draft\n  And PagePublished") }) do |_dir, path|
      result = Hecks::Behaviors.run(path)
      statuses = result.runs.to_h { |run| [run.description, run.status] }

      expect(statuses["A drafted page can be published"]).to eq(:fail)
      expect(statuses["A page comes off the site and goes back on"]).to eq(:pass)
    end
  end

  it "enforces the role: a viewer is refused, and the same step by an editor is not" do
    with_examples(->(text) { text.sub("Sam is a Viewer", "Sam is an Editor") }) do |_dir, path|
      result = Hecks::Behaviors.run(path)
      sam = result.runs.find { |run| run.description.end_with?("(Sam)") }

      expect(sam.status).to eq(:fail)
      expect(sam.message).to include("expected refused")
    end
  end

  it "reports an example the parser refuses as a parse error naming its line and column" do
    with_examples(->(text) { text.sub("Given Dana drafts", "Given Pat drafts") }) do |_dir, path|
      result = Hecks::Behaviors.run(path)

      expect(result.runs).to be_empty
      expect(result.parse_error).to match(/page\.examples:\d+:\d+: I don't know who 'Pat' is/)
    end
  end

  it "says so when no chapter file stands beside the examples" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "orphan.examples")
      File.write(path, "Examples for: Cms\n")

      expect(Hecks::Behaviors.run(path).parse_error).to include("no .bluebook beside it declares Cms")
    end
  end

  it "is found by a sweep of the directory, beside any .behaviors files" do
    with_examples do |dir, _path|
      sweep = Hecks::Behaviors.run_all(dir)

      expect(sweep.files_swept).to eq(1)
      expect(sweep.summary).to include(passed: 5, failed: 0, errored: 0)
    end
  end
end

require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/workflow_pagination"

# A step that counts a run's artifacts from the first page of a list that pages at 30 stops
# counting once the run holds more than that.
RSpec.describe Hecks::WorkflowPagination do
  let(:root) { Dir.mktmpdir("workflow-pagination") }

  after { FileUtils.remove_entry(root) }

  define_method(:workflow) do |step, path: ".github/workflows/ci.yml"|
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), "jobs:\n  a:\n    steps:\n      - run: |\n#{step.gsub(/^/, "          ")}")
  end

  define_method(:findings) { described_class.findings(root) }

  ARTIFACT_WAIT = <<~SH.freeze
    for _ in $(seq 1 90); do
      found=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/artifacts" \\
              --jq '[.artifacts[] | select(.name | startswith("host-wasm-"))] | length')
      [ "$found" = "3" ] && exit 0
    done
  SH

  it "flags the artifact wait that counts the first page", :aggregate_failures do
    workflow(ARTIFACT_WAIT)

    expect(findings.size).to eq(1)
    expect(findings.first).to start_with(".github/workflows/ci.yml:6: counts or waits for the items of repos/")
  end

  it "names the fix" do
    workflow(ARTIFACT_WAIT)

    expect(findings.first).to include("add --paginate")
  end

  it "passes the same wait once it paginates" do
    workflow(ARTIFACT_WAIT.sub("gh api ", "gh api --paginate "))

    expect(findings).to be_empty
  end

  it "passes a call filtered to one name" do
    workflow(ARTIFACT_WAIT.sub("/artifacts\"", "/artifacts?name=host-wasm-1\""))

    expect(findings).to be_empty
  end

  it "passes a per_page=100 call whose count is bounded by a number" do
    workflow(ARTIFACT_WAIT.sub("/artifacts\"", "/artifacts?per_page=100\""))

    expect(findings).to be_empty
  end

  it "flags a per_page=100 call that is compared with no number" do
    workflow(ARTIFACT_WAIT.sub("/artifacts\"", "/artifacts?per_page=100\"").sub('= "3"', "= \"$expected\""))

    expect(findings.size).to eq(1)
  end

  it "passes a call that reads total_count, which pagination does not change" do
    workflow("n=$(gh api \"repos/$GITHUB_REPOSITORY/actions/runs/$ID/jobs\" --jq .total_count)\n")

    expect(findings).to be_empty
  end

  it "flags a count of a list in a composite action" do
    workflow("gh api repos/$R/issues --jq 'length'\n", path: ".github/actions/x/action.yml")

    expect(findings.first).to start_with(".github/actions/x/action.yml:")
  end

  it "passes a call on a single item" do
    workflow("gh api repos/$R/actions/runs/$ID --jq '.status | length'\n")

    expect(findings).to be_empty
  end

  it "raises with the findings from .check" do
    workflow(ARTIFACT_WAIT)

    expect { described_class.check(root: root) }.to raise_error(described_class::Failure, /ci\.yml:6/)
  end
end

require "spec_helper"
require "hecks/vocabulary"
require "hecks/release/version_commit"

# The `PublishingRule` rows of the Vocabulary bluebook name what a release reads. release.yml
# still runs its own shell (no behaviour moves here), so this spec holds the workflow to the rows:
# a row changed without the workflow, or a workflow edited away from its row, fails the suite.
RSpec.describe "the publishing rules the release workflow repeats" do
  let(:rules) { Hecks::Vocabulary.rows("PublishingRule").to_h { |rule| [rule.fetch("name"), rule.fetch("value")] } }
  let(:workflow) { File.read(File.join(InMemoryDomain::ROOT, ".github/workflows/release.yml")) }

  it "names every rule the release reads" do
    expect(rules.keys).to contain_exactly("version_line", "push_attempts", "push_backoff_seconds",
                                          "push_done_pattern", "push_refused_pattern")
  end

  it "reads the version line from its row" do
    expect(Hecks::Release::VersionCommit::VERSION_LINE).to eq(rules.fetch("version_line"))
  end

  it "finds the commit that set the version with the same line" do
    expect(workflow).to include("-G'#{rules.fetch("version_line")}'")
  end

  it "retries the gem push as many times as its row says, with the backoff its row names" do
    attempts = rules.fetch("push_attempts").to_i
    backoff = rules.fetch("push_backoff_seconds").to_i

    expect(workflow).to include("for attempt in #{(1..attempts).to_a.join(" ")}; do", "sleep $((attempt * #{backoff}))")
  end

  it "matches the done and refused output the rows name" do
    expect(workflow).to include("grep -qiE '#{rules.fetch("push_done_pattern")}' push.log",
                                "grep -qiE '#{rules.fetch("push_refused_pattern")}' push.log")
  end
end

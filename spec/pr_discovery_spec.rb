require_relative "../qa/lib/pr_discovery"

# bin/qa_pr_check is a SCRIPT with real side effects (a real ledger boot,
# real `gh` calls) — same reasoning bin_stores_spec.rb's own header gives
# for testing other `bin/` scripts as real subprocesses. But the one
# defect this regression pins (PR #534, invisible to an earlier version
# of this script) lives entirely in `Hecks::QA::PrDiscovery.candidate?`
# (qa/lib/pr_discovery.rb) — a small, pure, namespaced module with no
# `gh` call and no ledger involved. `require_relative` it directly rather
# than `load`ing bin/qa_pr_check itself: an EARLIER version of this spec
# did exactly that (`load` the whole script, relying on its own
# `if __FILE__ == $PROGRAM_NAME` guard to skip the side-effecting part),
# and it was a real, confirmed-live mistake — the script used to define
# `candidate_pr?` (and `field`, `q`, `gh`, `ROOT`, ...) as bare top-level
# `def`s/constants, which `load` turns into PRIVATE METHODS AND CONSTANTS
# ON `Object` ITSELF, leaking into every other spec file sharing the same
# process for the rest of the run. The symptom was exactly this
# repository's own load-hygiene concern (see load_hygiene_spec.rb):
# the FULL suite's own example count went flaky run to run — 2560, then
# 1646, then 133, then 49 — with zero reported failures each time, purely
# from file-load-order-dependent method/constant collisions. Extracting
# the filter into `Hecks::QA::PrDiscovery` and `require_relative`-ing it
# here (the ordinary, hygienic way) fixed that at the root; this comment
# stays as the reason `load` is never coming back to this file.
RSpec.describe Hecks::QA::PrDiscovery do
  # THE EXACT SHAPE `gh pr list --json number,headRefName,headRefOid,url,
  # title,isDraft` hands back, symbolized the same way bin/qa_pr_check
  # itself parses it (`JSON.parse(list_out, symbolize_names: true)`).
  def pr(title:, head_ref_name:, is_draft:, number: 1)
    { number: number, headRefName: head_ref_name, headRefOid: "a" * 40, url: "https://example.com/pr/#{number}",
      title: title, isDraft: is_draft }
  end

  describe ".candidate?" do
    # THE REGRESSION ITSELF — PR #534: title "qa: fix quality_control.
    # world's dropdb guidance; pin dotted-hop shadow-parse behavior",
    # genuinely open, genuinely red CI, opened from an agent worktree
    # branch (`worktree-agent-<hash>`, never renamed to `loop-parity/
    # <slug>`) and kept DRAFT forever, per this repository's own
    # standing hecks_qa convention. An earlier version of this script's
    # `gh pr list --search "head:loop-parity"` found nothing for exactly
    # this PR — confirmed live against the real repo, not assumed (see
    # qa/lib/pr_discovery.rb's own header comment). This is the scenario
    # that PR would have needed to pass, reconstructed as a plain PR hash
    # so the check never depends on GitHub actually having such a PR open.
    it "finds a DRAFT PR whose branch does not follow loop-parity/*, purely by its qa: title" do
      title = "qa: fix quality_control.world's dropdb guidance; pin dotted-hop shadow-parse behavior"
      regression_pr = pr(title: title, head_ref_name: "worktree-agent-a40959be25ea6c419", is_draft: true,
                         number: 534)

      expect(described_class.candidate?(regression_pr)).to be(true)
    end

    it "still finds a loop-parity/* branch whose title does not happen to start with qa:" do
      expect(described_class.candidate?(pr(title: "fix the thing", head_ref_name: "loop-parity/some-slug",
                                           is_draft: true))).to be(true)
    end

    it "does not match an unrelated PR (neither qa: title nor loop-parity/* branch)" do
      expect(described_class.candidate?(pr(title:         "bump some-gem to 2.0",
                                           head_ref_name: "dependabot/bundler/some-gem-2.0",
                                           is_draft:      false))).to be(false)
    end

    it "is indifferent to draft state either way — being a draft neither adds nor removes a match" do
      ready = pr(title: "qa: something", head_ref_name: "irrelevant-branch", is_draft: false)
      draft = pr(title: "qa: something", head_ref_name: "irrelevant-branch", is_draft: true)

      expect(described_class.candidate?(ready)).to be(true)
      expect(described_class.candidate?(draft)).to be(true)
    end
  end

  # THE OTHER HALF OF THE HYPOTHESIS, DISPROVEN — confirmed live in
  # qa/lib/pr_discovery.rb's own header comment: `gh pr list` does not
  # exclude drafts by default, with or without `--search`. Nothing to
  # unit-test about gh's own default behavior (that would mean shelling
  # out for real, which this suite deliberately does not do — see
  # spec/adapters/github_checks_spec.rb's own header on why), but the
  # discovery call bin/qa_pr_check makes is pinned here so a future edit
  # cannot quietly reintroduce a `--search` filter that excludes drafts
  # again without this line changing too.
  it "bin/qa_pr_check asks gh for every open PR with no --search filter, so gh's own defaults can never exclude a draft" do
    script_source = File.read(File.join(InMemoryDomain::ROOT, "bin/qa_pr_check"))

    expect(script_source).to include('gh("pr", "list", "--state", "open"')
    expect(script_source).not_to match(/gh\("pr",\s*"list".*"--search"/)
  end
end

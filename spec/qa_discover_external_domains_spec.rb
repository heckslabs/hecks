require "spec_helper"
require_relative "support/qa_lib_cli"

# `hecks quality_control discover_external_domains` — rotation-widening discovery over
# `~/Projects`; `--known-path` bypasses the real ledger so this proves the script itself.
RSpec.describe "hecks quality_control discover_external_domains" do
  # Not `FIXTURES` — spec/runtime/storage_shape_spec.rb already owns that
  # name; every spec loads into one process, so reusing it silently reads whichever file loaded
  # last.
  DISCOVER_EXTERNAL_DOMAINS_FIXTURES =
    File.join(InMemoryDomain::ROOT, "spec/fixtures/qa_discover_external_domains/projects").freeze

  def run_discover(*args)
    QaLibCli.capture3("qa_discover_external_domains", "--projects-dir", DISCOVER_EXTERNAL_DOMAINS_FIXTURES,
                      "--known-path", "/nowhere-already-identified", *args)
  end

  # The report names the domain, its absolute path, and the command that enrolls it.
  def expect_enrolled(out, reference, path = reference)
    full = File.join(DISCOVER_EXTERNAL_DOMAINS_FIXTURES, path)

    expect(out).to include(reference, full, "hecks run qa/bluebook identify reference=#{reference} path=#{full}")
  end

  it "reports the one bluebook-shaped, hecks-dependent domain in the qualifying sibling, with its enroll command",
     :aggregate_failures do
    out, err, status = run_discover

    expect(status.exitstatus).to eq(0), "stdout:\n#{out}\nstderr:\n#{err}"
    expect_enrolled(out, "qualifying_sibling/widgets")
  end

  it "never reports ~/Projects/hecks itself", :aggregate_failures do
    out, _err, status = run_discover

    expect(status.exitstatus).to eq(0)
    expect(out).not_to include("reference=hecks/")
  end

  it "skips a bluebook-shaped directory whose own name does not match the bluebook file's basename", :aggregate_failures do
    out, _err, status = run_discover

    expect(status.exitstatus).to eq(0)
    expect(out).not_to include("mismatch")
    expect(out).not_to include("qualifying_sibling/other")
  end

  it "skips a project with no hecks dependency at all, even with a bluebook-shaped directory", :aggregate_failures do
    out, _err, status = run_discover

    expect(status.exitstatus).to eq(0)
    expect(out).to include("no hecks dependency, skipped:").and include("unrelated_repo")
    expect(out).not_to include("unrelated_repo/widgets")
  end

  it "does not false-positive on a near-miss gem name like hecks_fork", :aggregate_failures do
    out, _err, status = run_discover

    expect(status.exitstatus).to eq(0)
    expect(out).to include("no hecks dependency, skipped:").and include("near_miss_repo")
    expect(out).not_to include("near_miss_repo/thing")
  end

  it "recognises a Gemfile.lock-only dependency (no `gem \"hecks\"` line in Gemfile itself)", :aggregate_failures do
    out, _err, status = run_discover

    expect(status.exitstatus).to eq(0)
    expect(out).to include("lockfile_only_repo/gadget")
  end

  it "prunes a vendored copy of hecks's own examples rather than re-reporting them as new", :aggregate_failures do
    out, _err, status = run_discover

    expect(status.exitstatus).to eq(0)
    expect(out).not_to include("vendor/hecks")
    expect(out).not_to include("reference=qualifying_sibling/pizzas")
  end

  it "skips a candidate already on file as a Target, via --known-path", :aggregate_failures do
    widgets_path = File.join(DISCOVER_EXTERNAL_DOMAINS_FIXTURES, "qualifying_sibling/widgets")
    out, _err, status = run_discover("--known-path", widgets_path)

    expect(status.exitstatus).to eq(0)
    expect(out).not_to include("reference=qualifying_sibling/widgets")
  end

  it "reports a root-shaped domain — <repo-root>/bluebook/<repo-name>.bluebook, the entity dir IS the " \
     "sibling's own root (a real client project's shape) — alongside a sibling adapters/ dir inside " \
     "bluebook/ that must not be mistaken for a second entity (a real translations/ dir is deliberately " \
     "NOT part of this fixture — see its own bluebook/adapters/README.md for why: that exact directory " \
     "name is itself a live corpus route this repo's own spec/translation/committed_edges_spec.rb reads, " \
     "and a fixture domain carrying one without a real translation edge breaks that spec, not this one)", :aggregate_failures do
    out, err, status = run_discover

    expect(status.exitstatus).to eq(0), "stdout:\n#{out}\nstderr:\n#{err}"
    expect_enrolled(out, "root_shaped_sibling/root_shaped_sibling", "root_shaped_sibling")
    expect(out).not_to include("root_shaped_sibling/adapters")
  end

  it "does not false-positive a root-shaped fork project: " \
     "a root-shaped bluebook reading `Hecks.bluebook`, backed by a vendored fork (`Hecks = HecksFork`), " \
     "never a dependency on the real hecks gem", :aggregate_failures do
    out, _err, status = run_discover

    expect(status.exitstatus).to eq(0)
    expect(out).to include("no hecks dependency, skipped:").and include("near_miss_root_shaped_repo")
    expect(out).not_to include("near_miss_root_shaped_repo/near_miss_root_shaped_repo")
  end

  it "finds qualifying_sibling/widgets by default", :aggregate_failures do
    out, _err, status = run_discover

    expect(status.exitstatus).to eq(0)
    expect(out).to include("qualifying_sibling/widgets")
  end

  it "narrows with --max-depth: depth 0 does not find qualifying_sibling/widgets", :aggregate_failures do
    out, _err, status = run_discover("--max-depth", "0")

    expect(status.exitstatus).to eq(0)
    expect(out).not_to include("qualifying_sibling/widgets")
  end

  it "finds a monorepo's hecks-dependent domain even though the sibling's own root carries no " \
     "Gemfile at all — the dependency is declared in a nested app directory's own Gemfile " \
     "(the shape of a monorepo with a nested app)", :aggregate_failures do
    out, err, status = run_discover

    expect(status.exitstatus).to eq(0), "stdout:\n#{out}\nstderr:\n#{err}"
    expect_enrolled(out, "monorepo_sibling/app")
    expect(out[/^no hecks dependency, skipped:.*$/].to_s).not_to include("monorepo_sibling")
  end

  it "exits 1 with usage on an unknown flag", :aggregate_failures do
    _out, err, status = QaLibCli.capture3("qa_discover_external_domains", "--nonsense")

    expect(status.exitstatus).to eq(1)
    expect(err).to include("usage: hecks quality_control discover_external_domains")
  end

  it "exits 1 when --projects-dir does not exist", :aggregate_failures do
    _out, err, status = QaLibCli.capture3("qa_discover_external_domains", "--projects-dir",
                                          "/definitely-not-a-real-path", "--known-path", "/x")

    expect(status.exitstatus).to eq(1)
    expect(err).to include("is not a directory")
  end
end

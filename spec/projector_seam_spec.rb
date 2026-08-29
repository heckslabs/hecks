require "spec_helper"

# ADR 0027 — canonical IR plus the Projector framework (§30 of
# HECKS_IMPLEMENTATION_PLAN.md) is the one seam nearly everything else in
# this project either builds or stands on. This is the mechanical half of
# that ADR's own "is this a projector?" question, made into an enforced
# gate rather than a question someone has to remember to ask — the same
# move ADR 0026 already made for "does the language use what it
# declares?" (spec/self_use_spec.rb).
#
# `lib/hecks/projections/` is the sanctioned home for a "canonical
# IR in, external artifact out" tool (`Projector::Target`'s own doc
# comment, lib/hecks/projector/target.rb) — every file there is
# expected to `extend Projector::Target` and `projects_as` a real key,
# self-registering at require time ("requireing a target is the whole of
# installing it" — target.rb's own words). This spec confirms nothing
# sits there unregistered, and separately names the OTHER two kinds
# `lib/hecks/projector.rb`'s own header already distinguishes — an
# EXPORT (needs a declaration's bindings, which `call(bluebook:,
# options:)` has no channel for) or a STATE PROJECTION (reads records,
# not a declaration) — so "why isn't X registered" has one checked
# answer, not archaeology, the same "never silence" discipline
# spec/fuzzing/meta_domain_coverage_spec.rb already holds the grammar to.
RSpec.describe "the seam between canonical IR and its projections (ADR 0027)" do
  PROJECTIONS_DIR = File.join(InMemoryDomain::ROOT, "lib/hecks/projections")

  it "registers every file in lib/hecks/projections/ as a live Projector target" do
    files = Dir.glob(File.join(PROJECTIONS_DIR, "*.rb"))
    expect(files).not_to be_empty,
                         "lib/hecks/projections/ is empty or missing — this spec's own path is stale"

    # `extend[\s(]+` on purpose, not just `extend\s+` — projections/ir.rb
    # writes this as `IR.extend(Projector::Target)`, a real, legitimate
    # method-call form every other file spells as a bare `extend
    # Projector::Target` instead. Confirmed by running this spec red
    # first: the narrower regex silently skipped ir.rb rather than
    # verifying it.
    findings = files.filter_map do |path|
      content = File.read(path)
      next unless content.match?(/extend[\s(]+[\w:]*Projector::Target\b/) ||
                  content.match?(/extend[\s(]+Target\b/)

      key_match = content.match(/projects_as\s+:(\w+)/)
      next "#{File.basename(path)} extends Projector::Target but declares no projects_as key" unless key_match

      key = key_match[1].to_sym
      next if Hecks::Projector.registered?(key)

      "#{File.basename(path)} declares projects_as :#{key}, but Hecks::Projector doesn't have it " \
        "live — registered: #{Hecks::Projector.registered.sort.inspect}"
    end

    expect(findings).to be_empty, findings.join("; ")
  end

  it "extends Projector::Target from every file that declares a projects_as key" do
    # THE OTHER DIRECTION — a file that calls `projects_as` without also
    # `extend`ing `Target` would raise NoMethodError the moment it loads,
    # so this can't silently drift the way the first check could; kept
    # as its own example anyway, so a future refactor that changes HOW
    # `projects_as` is reached (a module method instead of an `extend`)
    # gets a spec failure here rather than this file's own comment going
    # stale about what "the sanctioned way" currently is.
    files = Dir.glob(File.join(PROJECTIONS_DIR, "*.rb"))
    orphaned_projects_as = files.select do |path|
      content = File.read(path)
      content.match?(/projects_as\s+:\w+/) &&
        !(content.match?(/extend[\s(]+[\w:]*Projector::Target\b/) || content.match?(/extend[\s(]+Target\b/))
    end

    expect(orphaned_projects_as).to be_empty,
                                    "#{orphaned_projects_as.map { |p| File.basename(p) }.join(', ')} call projects_as without " \
                                    "extending Projector::Target"
  end

  # Real, named, reasoned — not an escape hatch. Each entry is a
  # construct that genuinely fits one of `lib/hecks/projector.rb`'s
  # OTHER two kinds (EXPORT or STATE PROJECTION), read and confirmed
  # against its own real code before being listed here, the same
  # discipline `spec/fuzzing/meta_domain_coverage_spec.rb`'s own
  # META_DOMAIN_KNOWN_GAPS holds every entry to.
  #
  # `Layout/HashAlignment`'s repo-wide `table` style (.rubocop.yml) would
  # force every reason string below onto the SAME column, leaving almost
  # no room to wrap under Layout/LineLength's own 130-column limit.
  # rubocop:disable-next Layout/HashAlignment
  KNOWN_NON_PROJECTIONS = {
    "lib/hecks/projector/exporter.rb" =>
        "registry-WIDE (call(registry), not call(bluebook:, options:)) — consumed directly by bin/ir, bin/project_rust, and " \
        "translation's own approval digest; narrower single-bluebook registration would be the wrong shape for what actually " \
        "calls it",
    "rust/project.rb"                 =>
        "an EXPORT — RustProjection::Projector needs a declaration's BINDINGS (.world/.hecksagon), which call(bluebook:, " \
        "options:) has no channel for; a whole second toolchain, not a registry entry",
    "bin/project_rust"                =>
        "the CLI driver for the EXPORT above",
    "bin/project_wasm"                =>
        "the same EXPORT, cross-compiled — wraps the SAME Rust binary bin/project_rust generates (ADR 0012), not a second " \
        "implementation",
    "bin/project_wasm_browser"        =>
        "the same EXPORT, browser-targeted — a separate binary from bin/project_wasm's own (ADR 0015), same reason",
    "bin/expression_projection"       =>
        "a STATE PROJECTION — replays expression_operators.json's own ledger of dispatches, not a chapter's declaration; its " \
        "own header already names this exact risk (\"however much its name suggests otherwise\")",
    "bin/history"                     =>
        "a STATE PROJECTION — reads a domain's stored journal/records, not its declaration",
    "bin/project_field_hints"         =>
        "a language-level constant-table mirror (Ruby's own FieldShape hints -> Rust) — no bluebook/chapter input at all, a " \
        "different kind of \"keep two tables in sync\" tool",
    "bin/project_kernel_capabilities" =>
        "the same kind of language-level constant-table mirror, for the Rust kernel's own capability enums",
    "bin/project_refusal_wording"     =>
        "the same kind of language-level constant-table mirror, for RefusalWording::TEMPLATES"
  }.freeze

  it "never lets the known-non-projection roster rot — every named file still exists" do
    missing = KNOWN_NON_PROJECTIONS.keys.reject { |path| File.exist?(File.join(InMemoryDomain::ROOT, path)) }
    expect(missing).to be_empty,
                       "named as a known non-projection but no longer exists: #{missing.join(', ')} — a rename or " \
                       "deletion left this roster pointing at nothing"
  end
end

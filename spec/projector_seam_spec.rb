require "spec_helper"

# Gate: every file in lib/hecks/projections/ registers a Projector::Target (ADR 0027).
# Exports and state projections are listed explicitly, never silently skipped.
RSpec.describe "the seam between canonical IR and its projections (ADR 0027)" do
  PROJECTIONS_DIR = File.join(InMemoryDomain::ROOT, "lib/hecks/projections")

  # `extend[\s(]+`, not `extend\s+`: projections/ir.rb writes `IR.extend(Projector::Target)`,
  # which the narrower regex skipped silently.
  def extends_target?(content)
    content.match?(/extend[\s(]+[\w:]*Projector::Target\b/) || content.match?(/extend[\s(]+Target\b/)
  end

  # What is wrong with the projection file at `path`, or nil when it registers a live target.
  def projection_finding(path)
    content = File.read(path)
    return unless extends_target?(content)

    key_match = content.match(/projects_as\s+:(\w+)/)
    return "#{File.basename(path)} extends Projector::Target but declares no projects_as key" unless key_match

    key = key_match[1].to_sym
    return if Hecks::Projector.registered?(key)

    "#{File.basename(path)} declares projects_as :#{key}, but Hecks::Projector doesn't have it " \
      "live — registered: #{Hecks::Projector.registered.sort.inspect}"
  end

  it "registers every file in lib/hecks/projections/ as a live Projector target", :aggregate_failures do
    files = Dir.glob(File.join(PROJECTIONS_DIR, "*.rb"))
    expect(files).not_to be_empty, "lib/hecks/projections/ is empty or missing — this spec's own path is stale"

    findings = files.filter_map { |path| projection_finding(path) }

    expect(findings).to be_empty, findings.join("; ")
  end

  # The projection files that declare a `projects_as` key without extending `Target`.
  def orphaned_projects_as
    Dir.glob(File.join(PROJECTIONS_DIR, "*.rb")).select do |path|
      content = File.read(path)
      content.match?(/projects_as\s+:\w+/) && !extends_target?(content)
    end
  end

  it "extends Projector::Target from every file that declares a projects_as key" do
    # The other direction: `projects_as` without `extend`ing `Target` raises NoMethodError on load.
    # Kept separate so a change to how `projects_as` is reached fails here.
    orphaned = orphaned_projects_as

    expect(orphaned).to be_empty,
                        "#{orphaned.map { |p| File.basename(p) }.join(", ")} call projects_as without extending Projector::Target"
  end

  # Each entry is a construct that genuinely is an export or state projection, not an escape hatch.
  KNOWN_NON_PROJECTIONS = [
    ["lib/hecks/projector/exporter.rb",
     "registry-WIDE (call(registry), not call(bluebook:, options:)) — consumed directly by hecks ir, hecks project_rust, " \
     "and translation's own approval digest; narrower single-bluebook registration would be the wrong " \
     "shape for what actually calls it"]
  ].to_h.freeze

  it "never lets the known-non-projection roster rot — every named file still exists" do
    missing = KNOWN_NON_PROJECTIONS.keys.reject { |path| File.exist?(File.join(InMemoryDomain::ROOT, path)) }
    expect(missing).to be_empty,
                       "named as a known non-projection but no longer exists: #{missing.join(", ")} — a rename or " \
                       "deletion left this roster pointing at nothing"
  end
end

require "spec_helper"

# A restricted door checks an argument by its name (ADR 0089), so every name a public command of
# the Hecks chapter takes has to be classified: denied, a path, a git ref, or known to be plain
# data. A new argument name that is none of these fails here, so whoever adds it decides.
RSpec.describe Hecks::Doors::McpDoorScope do
  # Names that carry data and reach nothing outside the domain's own files.
  PLAIN_ARGUMENTS = %w[
    aggregates arguments at body check context digest era example exclude fills format from_run gate
    host_version inner ir_version iterations kind name named new_name only opens package pairs_shape
    parallel profile rehearsal rehearsed_at required run runs seed_start seeds ships_from snapshot stage
    stdout steps strict subject tags targets timeout to verb version warmup winners word workers
  ].freeze

  let(:classes) do
    { denied: described_class::DENIED_ARGUMENTS, path: described_class::PATH_ARGUMENTS,
      ref: described_class::REF_ARGUMENTS, plain: PLAIN_ARGUMENTS }
  end

  let(:public_argument_names) do
    chapter = Hecks.boot(File.expand_path("../lib/hecks/hecks", __dir__), install_doors: false)
    cli = Hecks::Projector.call(:cli, bluebook: Hecks::Storehouse.bluebook_for(chapter), options: { program: "mcp" })
    cli[:commands].values.reject { |spec| spec[:internal] }
                  .flat_map { |spec| spec[:arguments].map { |argument| argument[:path].split(".").first } }.uniq
  end

  it "classifies every argument name of every public command of the Hecks chapter" do
    unclassified = public_argument_names - classes.values.flatten

    expect(unclassified).to be_empty,
                            "#{unclassified.sort.inspect} are argument names of a public command that the door " \
                            "policy does not classify: add each to McpDoorScope::DENIED_ARGUMENTS, " \
                            "PATH_ARGUMENTS or REF_ARGUMENTS, or to PLAIN_ARGUMENTS here if it reaches nothing"
  end

  it "keeps every name in one class only" do
    names = classes.values.flatten

    expect(names.tally.select { |_, count| count > 1 }.keys).to be_empty
  end

  it "has no name in PLAIN_ARGUMENTS that no public command takes any more" do
    expect(PLAIN_ARGUMENTS - public_argument_names).to be_empty
  end
end

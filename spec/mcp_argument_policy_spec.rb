require "spec_helper"

# A restricted server checks an argument by its name (ADR 0089), so every name a public command of
# the Hecks bluebook takes has to be classified: denied, a path, a git ref, or known to be plain
# data. A new argument name that is none of these fails here, so whoever adds it decides.
RSpec.describe Hecks::Adapters::Driving::McpScope do
  # Names that carry data and reach nothing outside the domain's own files.
  PLAIN_ARGUMENTS = %w[
    additive agent aggregates alert_key arguments at body budget check closes context crate declaration_cache digest email
    environment era example exclude expert fills format full_gate
    from_run
    gate inner ir_version iterations kind lane list_shards name named new_name no_ai number only opens package
    pairs_shape
    parallel persist_regressions pin profile required role run runs seed_start seeds shard ships_from
    stage stdout steps strict subject tags target targets timeout to top verb version warmup winners word workers
  ].freeze

  let(:classes) do
    { denied: described_class::DENIED_ARGUMENTS, path: described_class::PATH_ARGUMENTS,
      ref: described_class::REF_ARGUMENTS, plain: PLAIN_ARGUMENTS }
  end

  let(:public_argument_names) do
    declaration = Hecks.boot(File.expand_path("../lib/hecks/hecks", __dir__), install_driving: false)
    cli = Hecks::Projector.call(:cli, bluebook: Hecks::Storehouse.bluebook_for(declaration), options: { program: "mcp" })
    cli[:commands].values.reject { |spec| spec[:internal] }
                  .flat_map { |spec| spec[:arguments].map { |argument| argument[:path].split(".").first } }.uniq
  end

  it "classifies every argument name of every public command of the Hecks bluebook" do
    unclassified = public_argument_names - classes.values.flatten

    expect(unclassified).to be_empty,
                            "#{unclassified.sort.inspect} are argument names of a public command that the server " \
                            "policy does not classify: add each to McpScope::DENIED_ARGUMENTS, " \
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

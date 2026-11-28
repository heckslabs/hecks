require "spec_helper"

# A restricted server checks an argument by its name (ADR 0089), so every name a public command of
# the Hecks bluebook takes has to be classified: denied, a path, a git ref, or known to be plain
# data. A new argument name that is none of these fails here, so whoever adds it decides.
RSpec.describe Hecks::Adapters::Driving::McpScope do
  # Names that carry data and reach nothing outside the domain's own files.
  PLAIN_ARGUMENTS = %w[
    aggregates arguments at body budget cap check clock component context copy crate declaration_cache days dry dry_run
    email environment era example exclude fills format inner isolation iterations kind lane list_shards name named new_name
    only opens package pairs_shape parallel persist_regressions pin profile reason rehearsal_verdict required role run runs
    seed_start seeds shard stage stdout steps strict subject tags target targets ticks timeout to top turns verb warmup watermark
    winners word window_days workers
  ].freeze

  let(:classes) do
    { denied: described_class::DENIED_ARGUMENTS, path: described_class::PATH_ARGUMENTS,
      ref: described_class::REF_ARGUMENTS, plain: PLAIN_ARGUMENTS }
  end

  # The Hecks bluebook, which the server serves.
  let(:served_bluebooks) { [Hecks::Storehouse.bluebook_for(boot_hecks_in_memory)] }

  let(:public_argument_names) do
    served_bluebooks.flat_map { |bluebook| public_commands(bluebook) }
                    .flat_map { |spec| spec[:arguments].map { |argument| argument[:path].split(".").first } }.uniq
  end

  def public_commands(bluebook)
    cli = Hecks::Projector.call(:cli, bluebook: bluebook, options: { program: "mcp" })
    cli[:commands].values.reject { |spec| spec[:internal] }
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

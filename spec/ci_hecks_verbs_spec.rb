require "spec_helper"

# ADR 0080, step 10: the workflows and the pre-push hook call `hecks <verb>`, not `bin/`. Every
# verb they name must resolve through the launcher, and the `bin/` calls that remain are the ones
# no command replaces yet. A script leaving this list is a gate that moved; a script joining it is
# a gate that did not.
RSpec.describe "CI and hook calls of the hecks launcher" do
  CI_VERBS_ROOT = File.expand_path("..", __dir__)
  CI_VERBS_FILES = (Dir[File.join(CI_VERBS_ROOT, ".github/workflows/*.yml")] +
                    [File.join(CI_VERBS_ROOT, ".githooks/pre-push")]).freeze

  # `bin/` scripts a workflow or the hook still runs, with what keeps each there.
  CI_VERBS_BIN_CALLS = {
    # exe/hecks hands `model_check` to Hecks::CLI, which cannot sweep the corpus or take --wait.
    "model_check"   => "legacy exe/hecks route",
    # A query answers exit 0 whatever it reports, so it cannot fail a job.
    "corpus"        => "query, exit 0",
    "rust_coverage" => "query, exit 0"
  }.freeze

  # The lines of each file that run something, comments left out.
  def code_lines
    CI_VERBS_FILES.flat_map do |file|
      File.readlines(file).reject { |line| line.strip.start_with?("#") }.map { |line| [file, line] }
    end
  end

  it "calls only the bin scripts no command replaces yet" do
    called = code_lines.flat_map { |_, line| line.scan(%r{(?<![\w.-])bin/([a-z_]+)}).flatten }.uniq

    expect(called - CI_VERBS_BIN_CALLS.keys).to be_empty
  end

  it "names only verbs the launcher resolves" do
    calls = code_lines.flat_map do |_, line|
      line.scan(%r{exe/hecks ((?:ask |deploy )?)([a-z_]+)}).map { |kind, verb| [kind.strip, verb] }
    end.uniq
    hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_facade: false)

    expect(calls).not_to be_empty
    calls.each do |kind, verb|
      argv = [*(kind == "ask" ? [] : [kind]), verb, "--help"].reject(&:empty?)
      _, status = Hecks::Facade::CliRunner.call(runtime: hecks, argv: argv, program: "hecks")

      expect(status).to eq(0), "hecks #{[kind, verb].reject(&:empty?).join(' ')} does not resolve"
    end
  end

  it "runs every hecks call of a pull request on Memory" do
    action = File.read(File.join(CI_VERBS_ROOT, ".github/actions/hecks-environment/action.yml"))

    expect(action).to include("HECKS_ENVIRONMENT=memory")
    expect(action).to match(%r{merge_group.*refs/heads/main}m)
  end
end

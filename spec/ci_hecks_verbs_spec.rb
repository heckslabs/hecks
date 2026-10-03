require "spec_helper"

# ADR 0080, step 10: the workflows and the pre-push hook call `hecks <verb>`, not `bin/`. Every
# verb they name must resolve through the launcher, and none of them starts a `bin/` script.
RSpec.describe "CI and hook calls of the hecks launcher" do
  # Words exe/hecks hands to Hecks::CLI before the launcher; they are not qualified names.
  LEGACY_WORDS = %w[run docs narrate ir stores model_check smoke_test project_diagrams project_cli mcp].freeze

  CI_VERBS_ROOT = File.expand_path("..", __dir__)
  CI_VERBS_FILES = (Dir[File.join(CI_VERBS_ROOT, ".github/workflows/*.yml")] +
                    [File.join(CI_VERBS_ROOT, ".githooks/pre-push")]).freeze

  # The lines of each file that run something, comments left out.
  def code_lines
    CI_VERBS_FILES.flat_map do |file|
      File.readlines(file).reject { |line| line.strip.start_with?("#") }.map { |line| [file, line] }
    end
  end

  it "calls no bin script" do
    called = code_lines.flat_map { |_, line| line.scan(%r{(?<![\w.-])bin/([a-z_]+)}).flatten }.uniq

    expect(called).to be_empty
  end

  it "names only commands the launcher resolves, each with its aggregate" do
    found = code_lines.flat_map do |_, line|
      line.scan(%r{exe/hecks ((?:ask |query |deploy )?)([a-z_.]+)!?}).map { |kind, verb| [kind.strip, verb] }
    end
    calls = found.uniq.reject { |_, verb| LEGACY_WORDS.include?(verb) }
    hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)

    expect(calls).not_to be_empty
    calls.each do |kind, verb|
      argv = [kind, verb, "--help"].reject(&:empty?)
      _, status = Hecks::Doors::CliRunner.call(runtime: hecks, argv: argv, program: "hecks")

      expect(verb).to include("."), "hecks #{verb} is not qualified with its aggregate"
      expect(status).to eq(0), "hecks #{[kind, verb].reject(&:empty?).join(' ')} does not resolve"
    end
  end

  it "runs every hecks call of a pull request on Memory" do
    action = File.read(File.join(CI_VERBS_ROOT, ".github/actions/hecks-environment/action.yml"))

    expect(action).to include("HECKS_ENVIRONMENT=memory")
    expect(action).to match(%r{merge_group.*refs/heads/main}m)
  end
end

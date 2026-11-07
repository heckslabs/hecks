require "spec_helper"
require "hecks/vocabulary"

# The quick gate catches a stale committed Postgres io file list before a push, the check CI's
# `postgres_io_file_list` job runs.
RSpec.describe "the io_spec_list gate check" do
  let(:script) { Hecks::Vocabulary.rows("GateCheck").find { |row| row["name"] == "io_spec_list" }.fetch("script") }
  let(:workflow) { File.read(File.join(InMemoryDomain::ROOT, ".github/workflows/ci-postgres-io-parallel.yml")) }

  it "is a quick-stage check" do
    quick = Hecks::Vocabulary.rows("GateStage").find { |row| row["name"] == "quick" }

    expect(quick.fetch("checks").split(",")).to include("io_spec_list")
  end

  it "reads the exclude pattern from the workflow instead of copying it" do
    expect(script).to include("IO_PARALLEL_EXCLUDE_PATTERN").and(include("ci-postgres-io-parallel.yml"))
  end

  it "does not hold a copy of the pattern's file names" do
    expect(script).not_to include("parser_parity_spec")
  end

  it "checks the same committed list the workflow checks", :aggregate_failures do
    expect(workflow).to include("check=.github/postgres_io_spec_files.txt")
    expect(script).to include("check=.github/postgres_io_spec_files.txt")
  end

  it "is skipped when no spec file differs from origin/main" do
    expect(script).to include("git diff --name-only", "exit 0")
  end

  it "extracts the workflow's pattern the way the script does", :aggregate_failures do
    pattern = workflow[/^  IO_PARALLEL_EXCLUDE_PATTERN: '(.*)'$/, 1]

    expect(pattern).to include("parser_parity_spec")
    expect(Regexp.new(pattern)).to match("spec/dsl_spec.rb")
  end
end

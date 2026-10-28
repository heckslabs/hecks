require "spec_helper"
require "yaml"
require "tmpdir"
require "etc"
require "fileutils"
require "hecks/tools"
require "hecks/tools/ci_workflows"

# The CiPipeline chapter projects GitHub Actions workflows: the CiWorkflows chapter declares
# ci-rspec.yml as flat rows, `hecks regeneration_run.project_ci_pipeline` writes the file from them,
# and a check compares the file with the rows. This spec holds the projection to the workflow it
# replaced: spec/fixtures/ci_pipeline/ci-rspec.original.yml is that workflow as it was committed
# by hand, and the projection must parse to the same document, but for the changes made on purpose
# since (`deliberately_changed`). Comments and key order may differ.
RSpec.describe "the CiPipeline projection of ci-rspec.yml" do
  def root = Hecks::Tools::ROOT

  def workflow_path = File.join(root, ".github/workflows/ci-rspec.yml")

  # The domains a shard reads of the generated Rust tree, which its generated-rust step holds.
  def shard_domains = "lease_clock nested_pieces"

  def original
    @original ||= deliberately_changed(YAML.load_file(File.join(root, "spec/fixtures/ci_pipeline/ci-rspec.original.yml")))
  end

  # How many shards the suite is split across: the hand-written workflow had four, and a fifth
  # shortens the longest one.
  def shard_total = 5

  # The hand-written workflow with what was changed on purpose since: each shard names the domains
  # it reads, leaves out the specs tagged `generated_all`, which read the whole tree and run in
  # the drift job, and the suite is split across more shards.
  def deliberately_changed(document)
    job = document.dig("jobs", "rspec_shard")
    steps = job.fetch("steps")
    steps.find { |step| step["uses"] == "./.github/actions/generated-rust" }["with"] = { "domains" => shard_domains }
    parallel = steps.find { |step| step["name"].to_s.start_with?("rspec: parallel") }
    parallel["run"] = parallel["run"].sub("--tag ~fuzzing", "--tag ~fuzzing --tag ~generated_all")
    job.dig("strategy", "matrix")["group"] = (1..shard_total).to_a
    listing = steps.find { |step| step["name"].to_s.start_with?("Determine") }
    listing["run"] = listing["run"].sub("groups=4", "groups=#{shard_total}")
    document
  end

  def projected_text = @projected_text ||= Hecks::Tools::CiWorkflows.projection(root).fetch(workflow_path)

  def projected = @projected ||= YAML.safe_load(projected_text)

  # `on:` reads as the boolean key `true` in YAML 1.1, in the original and the projection alike.
  def triggers(document) = document.fetch(true)

  def job(document, name) = document.fetch("jobs").fetch(name)

  def jobs_of(document) = document.fetch("jobs").keys

  describe "what the rows project" do
    it "parses to the document the hand-written workflow parsed to" do
      expect(projected).to eq(original)
    end

    it "holds the same jobs and name", :aggregate_failures do
      expect(jobs_of(projected)).to eq(jobs_of(original))
      expect(projected.fetch("name")).to eq(original.fetch("name"))
    end

    it "holds the same needs, conditions, runners, time limits and permissions", :aggregate_failures do
      jobs_of(original).product(%w[needs if runs-on timeout-minutes permissions]).each do |name, key|
        expect(job(projected, name)[key]).to eq(job(original, name)[key]), "#{name} #{key}"
      end
    end

    it "holds the same strategy and matrix, the legs following the shard total", :aggregate_failures do
      strategy = job(projected, "rspec_shard").fetch("strategy")

      expect(strategy).to eq("fail-fast" => false, "matrix" => { "group" => (1..shard_total).to_a })
      expect(strategy).to eq(job(original, "rspec_shard").fetch("strategy"))
    end

    it "holds the same steps: uses, with, run, name, id and if", :aggregate_failures do
      jobs_of(original).each do |name|
        expect(job(projected, name).fetch("steps")).to eq(job(original, name).fetch("steps")), "#{name} steps"
      end
    end

    it "holds the same job outputs and environment", :aggregate_failures do
      jobs_of(original).product(%w[outputs env]).each do |name, key|
        expect(job(projected, name)[key]).to eq(job(original, name)[key]), "#{name} #{key}"
      end
    end

    it "holds the same triggers, including workflow_call and its secrets", :aggregate_failures do
      expect(triggers(projected)).to eq(triggers(original))
      expect(triggers(projected).dig("workflow_call", "secrets")).to eq(
        "HECKS_CI_ATTEST_KEY" => { "required" => false }, "HECKS_JOURNAL_DATABASE" => { "required" => false }
      )
    end

    it "has each shard hold only the domains it reads, and leave out the specs that read the whole tree",
       :aggregate_failures do
      steps = job(projected, "rspec_shard").fetch("steps")
      generated = steps.find { |step| step["uses"] == "./.github/actions/generated-rust" }
      parallel = steps.find { |step| step["name"].to_s.start_with?("rspec: parallel") }

      expect(generated.fetch("with")).to eq("domains" => shard_domains)
      expect(parallel.fetch("run")).to include("--tag ~generated_all")
    end

    it "names domains the corpus regenerates", :aggregate_failures do
      known = Hecks::Corpus.rust_domains.map(&:feature)

      expect(shard_domains.split).not_to be_empty
      expect(shard_domains.split - known).to be_empty
    end

    it "writes the one shard total into the matrix and into the command that names it" do
      steps = job(projected, "rspec_shard").fetch("steps")
      command = steps.find { |step| step["name"].to_s.start_with?("Determine") }.fetch("run")

      expect(command).to include("groups=#{job(projected, "rspec_shard").dig("strategy", "matrix", "group").size}")
    end
  end

  describe "the text" do
    it "starts with a banner naming the verb that writes it" do
      expect(projected_text).to start_with("# Generated by hecks regeneration_run.project_ci_pipeline.")
    end

    it "keeps the hand-written comments as modeled note text", :aggregate_failures do
      expect(projected_text).to include("# Separate job because a job-level `if:` cannot read a step output")
      expect(projected_text).to include("# Artifact only, never restored:")
    end

    it "folds a long condition with >-, which reads back as the one line" do
      expect(projected_text).to include("    if: >-\n")
    end

    it "is the same text on every run, and names no time or machine", :aggregate_failures do
      first = Hecks::Tools::CiWorkflows.projection(root)
      expect(Hecks::Tools::CiWorkflows.projection(root)).to eq(first)
      machine = [Dir.pwd, Etc.getlogin, Time.now.year.to_s].compact.reject(&:empty?)
      expect(machine.select { |name| projected_text.include?(name) }).to be_empty
    end
  end

  describe "the committed workflow" do
    it "holds exactly what the rows project" do
      expect(File.read(workflow_path)).to eq(projected_text),
                                          ".github/workflows/ci-rspec.yml has drifted from the rows - " \
                                          "run hecks regeneration_run.project_ci_pipeline --confirm"
    end
  end

  describe "main" do
    around do |example|
      Dir.mktmpdir("ci_pipeline_root") do |work|
        @work = work
        example.run
      end
    end

    def written = File.join(@work, ".github/workflows/ci-rspec.yml")

    def project = Hecks::Tools::CiWorkflows.main([], root: @work)

    def check = Hecks::Tools::CiWorkflows.main(["--check"], root: @work)

    it "answers 1 under --check when the file is absent, and writes nothing", :aggregate_failures do
      expect { expect(check).to eq(1) }.to output(%r{out of date: \.github/workflows/ci-rspec\.yml}).to_stderr
      expect(File).not_to exist(written)
    end

    it "writes the file when it is not a check, then answers 0 under --check", :aggregate_failures do
      expect { project }.to output(%r{wrote \.github/workflows/ci-rspec\.yml}).to_stdout
      expect(File.read(written)).to eq(projected_text)
      expect { expect(check).to eq(0) }.to output(/current/).to_stdout
    end

    it "names a file edited by hand, and leaves the edit alone under --check", :aggregate_failures do
      expect { project }.to output(/wrote/).to_stdout
      File.write(written, "#{File.read(written)}# edited by hand\n")
      expect { expect(check).to eq(1) }.to output(/out of date/).to_stderr
      expect(File.read(written)).to end_with("# edited by hand\n")
    end
  end

  # The rows are refused with the row named and, where a closed set or a join is wrong, the valid
  # members listed. Each case changes one row of the committed table.
  describe "the rows' refusals" do
    def table = Hecks::Projections::CiPipeline::Table

    def vocabulary = @vocabulary ||= table.vocabulary(@registry)

    def rows
      @rows ||= Hecks::Projections::CiPipeline::Table::Typing::SHAPES.keys.to_h do |object|
        [object, table.rows_of(table.chapter(@registry), object).map(&:dup)]
      end
    end

    def change(object, **match)
      rows.fetch(object).find { |row| match.all? { |key, value| row[key] == value } }
    end

    def read = table.new(rows, vocabulary: vocabulary)

    def be_refused(pattern) = raise_error(table::Invalid, pattern)

    before { @registry = Hecks::Tools::CiWorkflows.registry_for }

    it "accepts the committed rows" do
      expect { read }.not_to raise_error
    end

    it "refuses an action that is not a member, listing the members", :aggregate_failures do
      change("Step", job: "rspec_shard", name: "ruby")[:uses] = "./.github/actions/no-such-action"

      expect { read }.to be_refused(%r{Step ci-rspec\.yml/rspec_shard/ruby has uses "\./\.github/actions/no-such-action"})
      expect { read }.to be_refused(%r{uses is one of \./\.github/actions/cargo-cache.*actions/upload-artifact@v4})
    end

    it "refuses a need naming a job the workflow does not declare, listing its jobs" do
      change("Need", job: "rspec_shard")[:needs] = "ci_attestation_rspecc"

      expect { read }.to be_refused(/names job "ci_attestation_rspecc", which workflow ci-rspec\.yml does not declare; its jobs/)
    end

    it "refuses jobs that need each other in a circle, naming the jobs" do
      rows.fetch("Need") << { workflow: "ci-rspec.yml", job: "ci_attestation_rspec", needs: "rspec_shard" }

      expect { read }.to be_refused(/in a circle: ci_attestation_rspec -> rspec_shard -> ci_attestation_rspec/)
    end

    it "refuses a job that needs itself" do
      rows.fetch("Need") << { workflow: "ci-rspec.yml", job: "rspec_shard", needs: "rspec_shard" }

      expect { read }.to be_refused(/in a circle: rspec_shard -> rspec_shard/)
    end

    it "refuses a step that both uses an action and runs a command" do
      change("Step", job: "rspec_shard", name: "ruby")[:run] = "make"

      expect { read }.to be_refused(%r{Step ci-rspec\.yml/rspec_shard/ruby has both uses and run})
    end

    it "refuses a step that neither uses an action nor runs a command" do
      change("Step", job: "rspec_shard", name: "ruby")[:uses] = ""

      expect { read }.to be_refused(%r{Step ci-rspec\.yml/rspec_shard/ruby has neither uses nor run})
    end

    it "refuses a shard total below one" do
      change("Job", name: "rspec_shard")[:shard_total] = 0

      expect { read }.to be_refused(%r{Job ci-rspec\.yml/rspec_shard has shard_total 0; a sharded job has at least one})
    end

    it "refuses a trigger that is not a member, listing the members" do
      change("Trigger", workflow: "ci-rspec.yml")[:event] = "on_full_moon"

      expect { read }.to be_refused(/has event "on_full_moon"; an event is one of push_main, pull_request, workflow_call/)
    end

    it "refuses a step input naming a step its job does not declare, listing the steps" do
      change("StepInput", step: "attest", key: "checks")[:step] = "attestt"

      expect { read }.to be_refused(/names step "attestt", which job ci_attestation_rspec does not declare; its steps are/)
    end

    it "refuses secrets on a workflow no other workflow can call" do
      rows.fetch("Trigger").replace([{ workflow: "ci-rspec.yml", event: "pull_request" }])

      expect { read }.to be_refused(/has Secret rows but no workflow_call Trigger/)
    end

    it "refuses a command that writes the shard total in a job with no shards" do
      change("Job", name: "rspec_shard").merge!(shard_total: 1, shard_axis: "")

      expect { read }.to be_refused(/writes %\{shard_total\} but its job has no shards/)
    end

    it "names every problem at once" do
      change("Step", job: "rspec_shard", name: "ruby")[:uses] = "nope"
      change("Job", name: "rspec_shard")[:shard_total] = 0

      expect { read }.to be_refused(/\A(?=.*has uses "nope")(?=.*has shard_total 0)/m)
    end
  end
end

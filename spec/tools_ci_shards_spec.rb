require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "hecks/tools"
require "hecks/tools/ci_shards"

# The shard counts of the sharded CI jobs are `CiShards` rows of the Vocabulary chapter.
# `hecks regeneration_run.project_ci_shards` writes each row into the marked `strategy:` region of
# its workflow, and the job's steps read the count back as `strategy.job-total`, so no other place
# states it. This spec holds the committed workflows to the rows.
RSpec.describe Hecks::Tools::CiShards do
  let(:root) { Hecks::Tools::ROOT }

  def workflow(name) = YAML.load_file(File.join(root, ".github/workflows", name))

  describe "the committed workflows" do
    it "hold exactly what the CiShards rows project" do
      described_class.projection(root).each do |path, text|
        expect(File.read(path)).to eq(text),
                                   "#{path.delete_prefix("#{root}/")} has drifted from the CiShards rows — " \
                                   "run hecks regeneration_run.project_ci_shards"
      end
    end

    it "give each sharded job a matrix of exactly the groups its row names", :aggregate_failures do
      described_class.shards.each do |row|
        matrix = workflow(row.fetch("workflow")).dig("jobs", row.fetch("name"), "strategy", "matrix", "group")

        expect(matrix).to eq((1..Integer(row.fetch("count"))).to_a)
      end
    end

    it "keep a failing shard from cancelling the others", :aggregate_failures do
      described_class.shards.each do |row|
        strategy = workflow(row.fetch("workflow")).dig("jobs", row.fetch("name"), "strategy")

        expect(strategy["fail-fast"]).to be(false)
      end
    end

    # A count typed into a step would stop following its row, and `--only-group` would be
    # 1-indexed against the wrong total.
    it "state no group total in a step: the steps read strategy.job-total", :aggregate_failures do
      described_class.shards.each do |row|
        steps = workflow(row.fetch("workflow")).dig("jobs", row.fetch("name"), "steps").filter_map { |step| step["run"] }.join("\n")

        expect(steps).to include("strategy.job-total")
        expect(steps).not_to match(/groups=\d|-n \d+ --group-by/)
      end
    end
  end

  describe "main" do
    let(:work) { Dir.mktmpdir("ci_shards_root") }

    before do
      FileUtils.mkdir_p(File.join(work, ".github/workflows"))
      described_class.shards.map { |row| row.fetch("workflow") }.uniq.each do |name|
        FileUtils.cp(File.join(root, ".github/workflows", name), File.join(work, ".github/workflows", name))
      end
    end

    after { FileUtils.rm_rf(work) }

    def rspec_yml = File.join(work, ".github/workflows/ci-rspec.yml")

    def hand_edit(text) = text.sub("fail-fast: false", "fail-fast: true")

    it "answers 0 when every region is current", :aggregate_failures do
      expect { expect(described_class.main(["--check"], root: work)).to eq(0) }.to output(/every region current/).to_stdout
    end

    it "names a workflow whose region was edited by hand, and writes nothing under --check", :aggregate_failures do
      edited = hand_edit(File.read(rspec_yml))
      File.write(rspec_yml, edited)

      expect { expect(described_class.main(["--check"], root: work)).to eq(1) }
        .to output(%r{out of date: \.github/workflows/ci-rspec\.yml}).to_stderr
      expect(File.read(rspec_yml)).to eq(edited)
    end

    it "restores the region when it is not a check", :aggregate_failures do
      File.write(rspec_yml, hand_edit(File.read(rspec_yml)))

      expect { described_class.main([], root: work) }.to output(%r{wrote \.github/workflows/ci-rspec\.yml}).to_stdout
      expect(File.read(rspec_yml)).to eq(described_class.projection(work).fetch(rspec_yml))
    end

    it "refuses a workflow with no marked region for a job", :aggregate_failures do
      File.write(rspec_yml, File.read(rspec_yml).gsub(/^    # (BEGIN|END) GENERATED ci_shards rspec_shard.*\n/, ""))

      expect { described_class.main([], root: work) }
        .to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
        .and output(%r{no BEGIN/END GENERATED ci_shards rspec_shard region}).to_stderr
    end
  end
end

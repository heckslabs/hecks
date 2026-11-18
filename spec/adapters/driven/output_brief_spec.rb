require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/codebase/source_tree"

RSpec.describe Hecks::Adapters::OutputBrief do
  let(:job) { Dir.mktmpdir("output-brief") }
  let(:brief) { described_class.new(env: { "CLAUDE_JOB_DIR" => job }) }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  after { FileUtils.rm_rf(job) }

  # What the test runner prints for a run of passing examples and two failures, the first with a
  # backtrace of the given depth.
  def runner_text(frames: 60)
    passing = (1..50).map { |n| "  passes #{n}" }
    trace = (1..frames).map { |n| "     # ./lib/frame_#{n}.rb:#{n}:in `call'" }
    ["sample", *passing, "", "Failures:", "", "  1) sample breaks", "     boom", *trace, "",
     "  2) sample cracks", "     bang", "", "Finished in 0.01 seconds", "52 examples, 2 failures", "",
     "Failed examples:", "", "rspec ./spec/a_spec.rb:3 # sample breaks", "rspec ./spec/a_spec.rb:4 # sample cracks"].join("\n")
  end

  def filed_path(summary) = summary[/^full output: (\S+)/, 1]

  it "answers a short text unchanged" do
    expect(brief.call("2 examples, 0 failures", label: "run_spec_files")).to eq("2 examples, 0 failures")
  end

  it "files a long text under the job directory and names the file", :aggregate_failures do
    path = filed_path(brief.call(runner_text, label: "run_spec_files"))
    expect(path).to start_with(File.join(job, "tmp", "hecks-output", "run_spec_files-"))
    expect(File.read(path)).to eq(runner_text)
  end

  it "is far shorter than the text it files" do
    expect(brief.call(runner_text, label: "run_spec_files").lines.size).to be < 25
  end

  it "keeps the first failure with the head of its backtrace", :aggregate_failures do
    summary = brief.call(runner_text, label: "run_spec_files")
    expect(summary).to include("1) sample breaks", "boom", "frame_5.rb", "(55 more frames in the file)")
    expect(summary).not_to include("frame_6.rb", "sample cracks\n     bang")
  end

  it "keeps every failed example's location and ends with the counts", :aggregate_failures do
    summary = brief.call(runner_text, label: "run_spec_files")
    expect(summary).to include("rspec ./spec/a_spec.rb:3 # sample breaks", "rspec ./spec/a_spec.rb:4 # sample cracks")
    expect(summary.lines.last).to eq("52 examples, 2 failures")
  end

  it "lists each failure's first error line before the failed examples, which still end the answer", :aggregate_failures do
    summary = brief.call(runner_text, label: "run_spec_files")
    expect(summary).to include("Errors:\n  1. sample breaks: boom\n  2. sample cracks: bang")
    expect(summary.index("Errors:")).to be < summary.index("Failed examples:")
  end

  it "skips the source lines under Failure/Error to the message" do
    block = ["  1) a fails", "     Failure/Error: expect(x)", "       .to eq(1)", "", "       expected: 1", "            got: 2"]
    text = [*block, "", "Finished in 1 second", "1 example, 1 failure"].join("\n")
    errors = Hecks::Adapters::OutputBrief::FailureErrors.new(text.lines.map(&:chomp), 5)
    expect(errors.to_s).to eq("Errors:\n  1. a fails: expected: 1")
  end

  it "lists at most the limit and counts the rest" do
    lines = (1..4).flat_map { |n| ["  #{n}) f#{n}", "     boom #{n}", ""] }
    listed = Hecks::Adapters::OutputBrief::FailureErrors.new(lines, 2).to_s
    expect(listed.lines.last).to eq("  (2 more in the file)")
  end

  it "shows the opening lines of a red run that printed no failure block" do
    noise = Array.new(60, "  noise")
    text = ["An error occurred while loading ./spec/a_spec.rb", *noise, "0 examples, 0 failures, 1 error"].join("\n")
    expect(brief.call(text, label: "run_spec_files")).to include("An error occurred while loading", "more lines in the file")
  end

  it "answers a long green run as the file and the counts" do
    text = ((1..60).map { |n| "  passes #{n}" } + ["60 examples, 0 failures"]).join("\n")
    expect(brief.call(text, label: "run_suite").lines.map(&:chomp).reject(&:empty?).drop(1)).to eq(["60 examples, 0 failures"])
  end

  it "answers the whole text in CI, whose log is the record" do
    in_ci = described_class.new(env: { "CLAUDE_JOB_DIR" => job, "CI" => "true" })
    expect(in_ci.call(runner_text, label: "run_spec_files")).to eq(runner_text)
  end

  it "answers the whole text when HECKS_OUTPUT is full" do
    whole = described_class.new(env: { "CLAUDE_JOB_DIR" => job, "HECKS_OUTPUT" => "full" })
    expect(whole.call(runner_text, label: "run_spec_files")).to eq(runner_text)
  end

  it "answers the whole text when the file cannot be written" do
    File.write(File.join(job, "tmp"), "a file where the directory would be")
    expect(brief.call(runner_text, label: "run_spec_files")).to eq(runner_text)
  end

  it "removes a filed text older than the days it is kept", :aggregate_failures do
    old = filed_path(brief.call(runner_text, label: "old"))
    File.utime(Time.now - (8 * 86_400), Time.now - (8 * 86_400), old)
    fresh = filed_path(brief.call(runner_text, label: "fresh"))
    expect(File.exist?(old)).to be(false)
    expect(File.exist?(fresh)).to be(true)
  end

  describe "the text a real run prints" do
    let(:dir) { Dir.mktmpdir("output-brief-run") }
    let(:tree) { Hecks::Adapters::Codebase::Tree.new(root: dir) }

    after { FileUtils.rm_rf(dir) }

    # What `SpecFiles` refuses with for a file of one passing and two failing examples, each run
    # by the real test runner in a process of its own.
    def real_refusal
      File.write(File.join(dir, "b_spec.rb"), <<~RUBY)
        RSpec.describe "b" do
          it("holds") { expect(1).to eq(1) }
          it("breaks") { expect(1).to eq(2) }
          it("cracks") { raise "bang" }
        end
      RUBY
      Hecks::Adapters::Codebase::SpecFiles.new(tree).run(files: "b_spec.rb")
    rescue failure => e
      e.message
    end

    it "is summarised with its first failure, its failed examples and its counts", :aggregate_failures do
      summary = described_class::SpecSummary.new(real_refusal, "/filed.log", described_class::LIMITS).to_s
      expect(summary).to match(/^\s+1\) b (breaks|cracks)/).and match(%r{^rspec \./b_spec\.rb:\d+ # b breaks$})
      expect(summary).to include("b_spec.rb: 3 examples, 2 failures  FAILED", "failed: b_spec.rb (1 of 1 files)")
      expect(summary.lines.last).to eq("3 examples, 2 failures")
    end

    it "lists the first error line of each failed example", :aggregate_failures do
      summary = described_class::SpecSummary.new(real_refusal, "/filed.log", described_class::LIMITS).to_s
      expect(summary).to include("Errors:", "1. b breaks: expected: 2", "2. b cracks: RuntimeError:")
      expect(summary).not_to match(/^\s*1\) .*: /)
    end
  end

  describe "a spec run through the SourceTree port" do
    let(:test_runner) { Hecks::Adapters::Codebase::TestRunner }
    let(:run) do
      { operation: { value: "run_spec_example" }, file: { value: "spec/doc_banners_spec.rb" }, example: { value: " " } }
    end

    before { allow(described_class).to receive(:of) { |text, label:| "brief of #{label}: #{text}" } }
    after { test_runner.runner = nil }

    def runner_ending(status)
      test_runner.runner = lambda do |_args, _err, out|
        out.puts "1 example, #{status} failures"
        status
      end
    end

    it "briefs the report of a run that passed" do
      runner_ending(0)
      expect(Hecks::Adapters::SourceTree.new.perform(**run))
        .to eq(report: { value: "brief of run_spec_example: 1 example, 0 failures" })
    end

    it "briefs the refusal of a run that failed" do
      runner_ending(1)
      expect { Hecks::Adapters::SourceTree.new.perform(**run) }
        .to raise_error(failure, "brief of run_spec_example: 1 example, 1 failures")
    end

    it "leaves every other operation's refusal as its family worded it" do
      expect { Hecks::Adapters::SourceTree.new.perform(operation: { value: "no_such_operation" }) }
        .to raise_error(failure, /no task carries out/)
    end
  end
end

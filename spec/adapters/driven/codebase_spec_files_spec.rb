require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/codebase/spec_files"

RSpec.describe Hecks::Adapters::Codebase::SpecFiles do
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }
  let(:dir) { Dir.mktmpdir("spec-files") }
  let(:tree) { Hecks::Adapters::Codebase::Tree.new(root: dir) }
  let(:specs) { described_class.new(tree, runner: nested_safe_runner) }

  after { FileUtils.rm_rf(dir) }

  # A runner that always starts a new process: a spec cannot reset and start the test runner that
  # is running it, so the "one process" of shared isolation is a new process here.
  def nested_safe_runner
    real = Hecks::Adapters::Codebase::TestRunner.new(tree)
    Class.new do
      define_method(:outcome) { |args, env: {}, **| real.outcome(args, env: env, fresh: true) }
    end.new
  end

  # Writes a spec file of examples, each `name => expression` expected to be true.
  def spec_file(name, examples, prelude: "")
    body = examples.map { |text, check| "  it(#{text.inspect}) { expect(#{check}).to be(true) }\n" }.join
    File.write(File.join(dir, name), "#{prelude}\nRSpec.describe #{name.inspect} do\n#{body}end\n")
  end

  def run_files(*names, **options) = specs.run(files: names.join(" "), **options)

  def refusal(*names, **options)
    run_files(*names, **options)
  rescue failure => e
    e.message
  end

  before do
    spec_file("a_spec.rb", { "adds" => "1 + 1 == 2", "keeps" => "true" })
    spec_file("b_spec.rb", { "holds" => "true", "breaks" => "false" })
  end

  it "runs two files in one call and counts each", :aggregate_failures do
    spec_file("c_spec.rb", { "works" => "true" })
    report = run_files("a_spec.rb", "c_spec.rb")
    expect(report).to include("a_spec.rb: 2 examples, 0 failures", "c_spec.rb: 1 example, 0 failures")
    expect(report.lines.last).to eq("3 examples, 0 failures")
  end

  it "accepts files separated by newlines" do
    spec_file("c_spec.rb", { "works" => "true" })
    expect(specs.run(files: "a_spec.rb\nc_spec.rb").lines.last).to eq("3 examples, 0 failures")
  end

  it "refuses when a file fails, names it and ends with the counts", :aggregate_failures do
    message = refusal("a_spec.rb", "b_spec.rb")
    expect(message).to include("failed: b_spec.rb (1 of 2 files)", "b_spec.rb: 2 examples, 1 failure  FAILED")
    expect(message.lines.last).to eq("4 examples, 1 failure")
  end

  it "does not name a file that passed as failed" do
    expect(refusal("a_spec.rb", "b_spec.rb")).not_to include("failed: a_spec.rb")
  end

  it "applies the example filter to every file", :aggregate_failures do
    report = run_files("a_spec.rb", "b_spec.rb", example: "holds")
    expect(report).to include("a_spec.rb: 0 examples", "b_spec.rb: 1 example, 0 failures")
  end

  it "runs examples tagged out of a default run, as a one-file run does" do
    File.write(File.join(dir, "tagged_spec.rb"), "RSpec.describe \"t\", :io do\n  it(\"runs\") { expect(1).to eq(1) }\nend\n")
    expect(run_files("tagged_spec.rb")).to include("tagged_spec.rb: 1 example, 0 failures")
  end

  # A spec file whose one example sleeps past a two-second bound, writing where it is as every
  # example of the suite does (spec/support/spec_progress.rb).
  def hanging_refusal
    progress = File.join(LiveServices::ROOT, "spec/support/spec_progress")
    prelude = "require #{progress.inspect}\nSpecProgress.install(RSpec.configuration)"
    spec_file("hang_spec.rb", { "waits" => "sleep(30)" }, prelude: prelude)
    described_class.new(tree, runner: Hecks::Adapters::Codebase::TestRunner.new(tree, bound: 2)).run(files: "hang_spec.rb")
  rescue failure => e
    e.message
  end

  it "ends a file that runs past its bound and names the file and example", :aggregate_failures do
    message = hanging_refusal
    expect(message).to include("failed: hang_spec.rb", "ran past the 2-second bound (spec_bounds file_seconds)")
    expect(message).to include("in ./hang_spec.rb, example \"hang_spec.rb waits\"")
  end

  it "refuses a file that is not there, naming it" do
    expect(refusal("a_spec.rb", "nope_spec.rb")).to eq("no such spec file nope_spec.rb")
  end

  it "refuses an isolation it does not know" do
    expect(refusal("a_spec.rb", isolation: "fork")).to include("process or shared")
  end

  describe "isolation" do
    before do
      spec_file("leak_a_spec.rb", { "sets" => "true" }, prelude: "$spec_files_leak = true")
      spec_file("leak_b_spec.rb", { "starts clean" => "$spec_files_leak.nil?" })
    end

    it "keeps one file's state out of the next under process isolation" do
      expect(run_files("leak_a_spec.rb", "leak_b_spec.rb", isolation: "process").lines.last).to eq("2 examples, 0 failures")
    end

    it "lets state leak under shared isolation, and names the file it breaks", :aggregate_failures do
      message = refusal("leak_a_spec.rb", "leak_b_spec.rb", isolation: "shared")
      expect(message).to include("failed: leak_b_spec.rb (1 of 2 files)", "shared (one process; may expose order dependence)")
    end

    it "counts each file under shared isolation" do
      expect(run_files("a_spec.rb", isolation: "shared")).to include("a_spec.rb: 2 examples, 0 failures")
    end

    it "names a file that does not load" do
      File.write(File.join(dir, "broken_spec.rb"), "raise 'no'\n")
      expect(refusal("a_spec.rb", "broken_spec.rb", isolation: "shared")).to include("failed: broken_spec.rb")
    end
  end
end

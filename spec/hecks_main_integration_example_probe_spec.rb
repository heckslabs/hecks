require "spec_helper"
require "hecks/hecks/adapters/main_verification"
require_relative "support/red_train_repository"

# One probe of a red train's search: the failing example CI named by file and line, run in a copy
# by the description that line holds at the train's head. The launcher is a stand-in.
RSpec.describe Hecks::Adapters::MainIntegration::ExampleProbe do
  include RedTrainRepository

  let(:dir) { File.realpath(Dir.mktmpdir("hecks-example-probe")) }
  let(:repo) { File.join(dir, "main") }
  let(:shell) { instance_double(Hecks::Adapters::Shell, capture: result) }
  let(:result) { instance_double(Hecks::Adapters::Shell::Result, ok?: true, out: "", err: "") }
  let(:probe) { described_class.new(repo, head, shell: shell) }

  before do
    open_repository
    FileUtils.mkdir_p(File.join(repo, "spec"))
    File.write(File.join(repo, "spec/bad_spec.rb"), "RSpec.describe \"bad\" do\n  let(:one) { 1 }\n  it \"breaks the build\"\n")
    commit("a spec")
  end

  after { FileUtils.remove_entry(dir) }

  it "reads the example's description from the line CI named, at the train's head" do
    expect(probe.description("spec/bad_spec.rb", 3)).to eq("breaks the build")
  end

  it "matches every example of the file when the line declares none" do
    expect(probe.description("spec/bad_spec.rb", 2)).to eq(" ")
  end

  it "runs the example by its description in the copy" do
    probe.call(repo, ["spec/bad_spec.rb:3"])
    expect(shell).to have_received(:capture).with("exe/hecks", "test_suite_run.run_spec_example!", "file.value=spec/bad_spec.rb",
                                                  "example.value=breaks the build", "--wait", env: {}, chdir: repo)
  end

  it "runs nothing, and is green, in a copy that does not hold the spec file" do
    probe.call(dir, ["spec/bad_spec.rb:3"])
    expect(shell).not_to have_received(:capture)
  end

  it "is red when the launcher refuses the run" do
    allow(result).to receive(:ok?).and_return(false)
    expect { probe.call(repo, ["spec/bad_spec.rb:3"]) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /breaks the/)
  end
end

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/first_commit_facts"

# The facts of a branch's first commit since main, read from a real repository in a temp directory.
RSpec.describe Hecks::Adapters::FirstCommitFacts do
  let(:main_run) { instance_double(Hecks::Adapters::MainSpecRun) }
  let(:dir) { Dir.mktmpdir("first-commit") }
  let(:facts) { described_class.new(main_run: main_run) }

  after { FileUtils.rm_rf(dir) }

  def git(*args) = system("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", *args, out: File::NULL, err: File::NULL)

  def commit(path, text = "x\n")
    FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
    File.write(File.join(dir, path), text)
    git("add", ".")
    git("commit", "-m", path)
  end

  before do
    git("init", "-b", "main")
    commit("README.md")
    git("checkout", "-b", "work")
  end

  it "reports the first commit's files and no spec when it adds none", :aggregate_failures do
    commit("lib/a.rb")
    commit("spec/a_spec.rb")
    expect(facts.of(dir)).to include(first_paths: "lib/a.rb", first_spec: "none")
  end

  it "asks main to run the spec files the first commit adds" do
    commit("spec/a_spec.rb")
    allow(main_run).to receive(:call).and_return({ first_spec: "failed", first_example: "a fails" })
    expect(facts.of(dir)).to include(first_spec: "failed", first_example: "a fails")
  end

  it "leaves a behaviors file unchecked" do
    commit("lib/a/a.behaviors")
    expect(facts.of(dir)).to include(first_spec: "unchecked")
  end

  it "reports no files for a branch with no commit since main", :aggregate_failures do
    expect(facts.of(dir)).to include(first_paths: "", first_spec: "none")
  end
end

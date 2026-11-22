require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/codebase/spec_files"

RSpec.describe "a shared spec run's time bound", :io do
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }
  let(:dir) { Dir.mktmpdir("spec-files-bound") }
  let(:tree) { Hecks::Adapters::Codebase::Tree.new(root: dir) }
  let(:runner) { Hecks::Adapters::Codebase::TestRunner.new(tree, bound: 4) }
  let(:specs) { Hecks::Adapters::Codebase::SpecFiles.new(tree, runner: runner) }

  after { FileUtils.rm_rf(dir) }

  def sleeper(name, seconds)
    File.write(File.join(dir, name), "RSpec.describe #{name.inspect} do\n  it(\"waits\") { sleep #{seconds}; expect(1).to eq(1) }\nend\n")
  end

  def refusal(*names)
    specs.run(files: names.join(" "), isolation: "shared")
  rescue failure => e
    e.message
  end

  it "ends a hung shared run at its bound and names the file it was in", :aggregate_failures do
    sleeper("hung_spec.rb", 600)
    message = refusal("hung_spec.rb")
    expect(message).to include("ran past the 4-second bound", "hung_spec.rb  FAILED")
  end

  it "gives a batch the bound of each of its files, so slow files together are not read as a hang" do
    sleeper("one_spec.rb", 2)
    sleeper("two_spec.rb", 2)
    expect(specs.run(files: "one_spec.rb two_spec.rb", isolation: "shared")).to end_with("2 examples, 0 failures")
  end
end

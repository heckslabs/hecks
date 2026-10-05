require "spec_helper"
require "tmpdir"
require "open3"
require "fileutils"
require "hecks/hecks/adapters/codebase/source_tree"

RSpec.describe Hecks::Adapters::Codebase::TestRunner do
  let(:tree) { Hecks::Adapters::Codebase::Tree.new }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  after { described_class.runner = nil }

  it "hands the runner the example and the file, and answers what it printed" do
    asked = nil
    described_class.runner = lambda do |args, _err, out|
      asked = { args: args, cwd: Dir.pwd }
      out.puts "1 example, 0 failures"
      0
    end

    report = described_class.new(tree).run(file: "hecks.gemspec", example: "it says hello")

    expect(report).to eq("1 example, 0 failures")
    expect(asked[:args]).to eq(["--example", "it says hello", tree.path("hecks.gemspec")])
    expect(File.realpath(asked[:cwd])).to eq(File.realpath(tree.root))
  end

  it "refuses with what the runner printed when an example fails" do
    described_class.runner = lambda do |_args, _err, out|
      out.puts "1 example, 1 failure"
      1
    end

    expect { described_class.new(tree).run(file: "hecks.gemspec", example: "x") }
      .to raise_error(failure, "1 example, 1 failure")
  end

  it "refuses a run that printed nothing, since a real run always prints its summary" do
    described_class.runner = ->(*) { 0 }

    expect { described_class.new(tree).run(file: "hecks.gemspec", example: "x") }
      .to raise_error(failure, "the test runner printed nothing for hecks.gemspec")
  end

  it "refuses a spec file that is not there, without starting the runner" do
    described_class.runner = ->(*) { raise "the runner must not start" }

    expect { described_class.new(tree).run(file: "spec/no_such_spec.rb", example: "x") }
      .to raise_error(failure, "no such spec file spec/no_such_spec.rb")
  end

  it "runs a real example of a real spec file" do
    Dir.mktmpdir do |dir|
      FileUtils.touch(File.join(dir, "hecks.gemspec"))
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(File.join(dir, "one_spec.rb"), "RSpec.describe('one') { it('passes') { expect(1).to eq(1) } }\n")
      script = "require 'rspec/core'; puts RSpec::Core::Runner.run(['--example', 'passes', ARGV[0]])"

      out, status = Open3.capture2e(RbConfig.ruby, "-e", script, File.join(dir, "one_spec.rb"))

      expect(status).to be_success
      expect(out).to include("1 example, 0 failures")
    end
  end
end

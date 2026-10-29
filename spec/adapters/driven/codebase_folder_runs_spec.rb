require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/codebase/source_tree"

RSpec.describe "Spec runs in a folder of their own" do
  let(:changed_specs) { Hecks::Adapters::Codebase::ChangedSpecs }
  let(:test_runner) { Hecks::Adapters::Codebase::TestRunner }
  let(:test_suite) { Hecks::Adapters::Codebase::TestSuite }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  after { test_runner.runner = nil }

  # Installs a runner that notes the arguments it was given and where it ran; answers that note.
  def runner_noting_its_call
    asked = {}
    test_runner.runner = lambda do |args, _err, out|
      asked[:args] = args
      asked[:cwd] = Dir.pwd
      out.puts "1 example, 0 failures"
      0
    end
    asked
  end

  describe Hecks::Adapters::Codebase::ChangedSpecs do
    let(:specs) { %w[spec/lib/thing_spec.rb spec/other_spec.rb] }

    it "runs a changed spec itself" do
      expect(changed_specs.call(["spec/other_spec.rb"], specs)).to eq(["spec/other_spec.rb"])
    end

    it "runs the spec of the same name for a changed source file" do
      expect(changed_specs.call(["lib/thing.rb"], specs)).to eq(["spec/lib/thing_spec.rb"])
    end

    it "runs nothing for a change no spec is named after, rather than the whole suite" do
      expect(changed_specs.call(["lib/unnamed.rb"], specs)).to eq([])
    end

    it "lists the changed Ruby files that map to no spec, for the report" do
      expect(changed_specs.unmapped(["lib/thing.rb", "lib/unnamed.rb", "README.md"], specs))
        .to eq(["lib/unnamed.rb"])
    end
  end

  describe Hecks::Adapters::Codebase::TestRunner do
    it "hands the runner every path it is given, from the folder's root" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec"))
        tree = Hecks::Adapters::Codebase::Tree.new(root: dir)
        asked = runner_noting_its_call

        test_runner.new(tree).run_paths(paths: ["spec"], tags: "--tag io")

        expect(asked[:args]).to eq(["--tag", "io", "spec"])
        expect(File.realpath(asked[:cwd])).to eq(File.realpath(dir))
      end
    end

    it "refuses a path that is not there, without starting the runner" do
      Dir.mktmpdir do |dir|
        tree = Hecks::Adapters::Codebase::Tree.new(root: dir)
        test_runner.runner = ->(*) { raise "the runner must not start" }

        expect { test_runner.new(tree).run_paths(paths: ["spec/missing_spec.rb"]) }
          .to raise_error(failure, "no such spec spec/missing_spec.rb")
      end
    end
  end

  describe "the changed-file run in a folder under git" do
    def git(dir, *words)
      out, status = Open3.capture2e("git", "-C", dir, *words)
      raise out unless status.success?
    end

    around do |example|
      Dir.mktmpdir do |dir|
        @dir = dir
        git(dir, "init", "-q", "-b", "main")
        git(dir, "config", "user.email", "spec@example.com")
        git(dir, "config", "user.name", "spec")
        FileUtils.mkdir_p(File.join(dir, "spec"))
        FileUtils.mkdir_p(File.join(dir, "lib"))
        File.write(File.join(dir, "lib/thing.rb"), "# one\n")
        File.write(File.join(dir, "spec/thing_spec.rb"), "# spec\n")
        File.write(File.join(dir, "spec/other_spec.rb"), "# spec\n")
        git(dir, "add", ".")
        git(dir, "commit", "-q", "-m", "start")
        example.run
      end
    end

    it "runs only the spec the changed source file maps to" do
      File.write(File.join(@dir, "lib/thing.rb"), "# two\n")
      asked = runner_noting_its_call

      report = test_suite.call("run_changed", { base: "main" }, Hecks::Adapters::Codebase::Tree.new(root: @dir))

      expect(asked[:args]).to eq(["spec/thing_spec.rb"])
      expect(report).to eq("1 example, 0 failures")
    end

    it "counts an untracked file as changed" do
      File.write(File.join(@dir, "spec/new_spec.rb"), "# new\n")
      asked = runner_noting_its_call

      test_suite.call("run_changed", { base: "main" }, Hecks::Adapters::Codebase::Tree.new(root: @dir))

      expect(asked[:args]).to eq(["spec/new_spec.rb"])
    end

    it "says so and runs nothing when no spec maps to the changes" do
      File.write(File.join(@dir, "lib/unnamed.rb"), "# new\n")
      test_runner.runner = ->(*) { raise "the runner must not start" }

      report = test_suite.call("run_changed", { base: "main" }, Hecks::Adapters::Codebase::Tree.new(root: @dir))

      expect(report).to eq("no spec maps to the 1 changed file(s) since main; nothing run")
    end
  end

  describe "the whole-suite run" do
    it "runs the folder's spec directory" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec"))
        asked = runner_noting_its_call

        test_suite.call("run_suite", {}, Hecks::Adapters::Codebase::Tree.new(root: dir))

        expect(asked[:args]).to eq(["spec"])
      end
    end

    it "runs the minitest files of the spec directory too, and reports each one" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "spec/adds_test.rb"), <<~RUBY)
          require "minitest/autorun"
          class AddsTest < Minitest::Test
            def test_adds = assert_equal(2, 1 + 1)
          end
        RUBY
        runner_noting_its_call

        report = test_suite.call("run_suite", {}, Hecks::Adapters::Codebase::Tree.new(root: dir))

        expect(report).to include("spec/adds_test.rb: 1 runs, 1 assertions, 0 failures, 0 errors, 0 skips")
      end
    end

    it "refuses with the minitest output when one of those files fails" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "spec/broken_test.rb"), <<~RUBY)
          require "minitest/autorun"
          class BrokenTest < Minitest::Test
            def test_breaks = assert_equal(3, 1 + 1)
          end
        RUBY
        runner_noting_its_call

        expect { test_suite.call("run_suite", {}, Hecks::Adapters::Codebase::Tree.new(root: dir)) }
          .to raise_error(failure, /spec\/broken_test.rb failed/)
      end
    end
  end

  describe "the folder check that lets a run in" do
    it "accepts a folder with a spec directory, though it is not a hecks checkout" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec"))

        answer = Hecks::Adapters::SourceTree.new.examine(operation: "run_suite", root: dir)

        expect(answer[:checkout]).to eq({ value: true })
      end
    end

    it "refuses a folder with no spec directory" do
      Dir.mktmpdir do |dir|
        answer = Hecks::Adapters::SourceTree.new.examine(operation: "run_suite", root: dir)

        expect(answer[:checkout]).to eq({ value: false })
      end
    end
  end
end

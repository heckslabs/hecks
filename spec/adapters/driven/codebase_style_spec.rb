require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/codebase/source_tree"

RSpec.describe Hecks::Adapters::Codebase::Style do
  let(:tree) { Hecks::Adapters::Codebase::Tree.new }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  # Answers a fixed output and status for every child process, and remembers what was asked.
  let(:shell_class) do
    Class.new do
      attr_reader :asked

      def initialize(out = "", status = 0)
        (@out = out
         @status = status
         @asked = [])
      end

      def capture(*command, env: {}, chdir: nil)
        @asked << { command: command[1..], env: env, chdir: chdir }
        Hecks::Adapters::Shell::Result.new(@out, "", Struct.new(:success?, :exitstatus).new(@status.zero?, @status))
      end
    end
  end

  def style(operation, held, shell: shell_class.new)
    described_class.call(operation, held, tree, shell: shell)
  end

  def word(value) = { value: value }

  describe "a check" do
    it "runs the Ruby linter with --check on each path, from the checkout's root" do
      shell = shell_class.new

      expect(style("check_comments", { paths: word("lib/a.rb,lib/b") }, shell: shell)).to eq("no comment violations")
      expect(shell.asked.first[:command]).to eq([tree.path("bin/standardize_comments"), "--check", "lib/a.rb", "lib/b"])
      expect(shell.asked.first[:chdir]).to eq(tree.root)
      expect(shell.asked.first[:env]).to include("HECKS_NO_3_0_NOTICE" => "1")
    end

    it "limits the categories when only is named" do
      shell = shell_class.new

      style("check_comments", { paths: word("lib"), only: word("long_line,all_caps") }, shell: shell)

      expect(shell.asked.first[:command]).to eq([tree.path("bin/standardize_comments"), "--check", "--only",
                                                 "long_line,all_caps", "lib"])
    end

    it "refuses with every violation the linter listed" do
      shell = shell_class.new("lib/a.rb:3: [long_line] 101 characters\n", 1)

      expect { style("check_comments", { paths: word("lib") }, shell: shell) }
        .to raise_error(failure, "lib/a.rb:3: [long_line] 101 characters")
    end

    it "runs the Rust linter for the Rust check" do
      shell = shell_class.new

      style("check_rust_comments", { paths: word("rust/src") }, shell: shell)

      expect(shell.asked.first[:command].first).to eq(tree.path("bin/standardize_comments_rust"))
    end
  end

  describe "a fix" do
    it "lists the fixable violations and rewrites nothing unless confirmed" do
      shell = shell_class.new("lib/a.rb:3: [long_line] 101 characters\nlib/a.rb:9: [all_caps] SHOUT\n", 1)

      report = style("fix_comments", { paths: word("lib") }, shell: shell)

      expect(report).to start_with("dry run, 2 violations a fix would rewrite (add --confirm to rewrite):")
      expect(shell.asked.map { |ask| ask[:command] })
        .to eq([[tree.path("bin/standardize_comments"), "--check", "--only", "all_caps,long_bold,long_line", "lib"]])
    end

    it "says so when there is nothing to rewrite" do
      expect(style("fix_rust_comments", { paths: word("rust") })).to eq("dry run: nothing a fix would rewrite")
    end

    it "rewrites with --fix when confirmed" do
      shell = shell_class.new("rewrote 2 files\n")

      report = style("fix_comments", { paths: word("lib"), confirm: word(true) }, shell: shell)

      expect(report).to eq("rewrote 2 files")
      expect(shell.asked.first[:command]).to eq([tree.path("bin/standardize_comments"), "--fix", "lib"])
    end
  end

  describe "the baseline" do
    it "lists the blocks it would record for lib/hecks, and writes nothing, unless confirmed" do
      shell = shell_class.new("lib/hecks/a.rb:4: [long_block] 14 lines\n", 1)

      report = style("write_comment_baseline", {}, shell: shell)

      expect(report).to start_with("dry run, 1 blocks would be recorded as tolerated (add --confirm):")
      expect(shell.asked.first[:command]).to eq([tree.path("bin/standardize_comments"), "--check", "--only",
                                                 "long_block", "lib/hecks"])
    end

    it "records the blocks with --write-baseline when confirmed" do
      shell = shell_class.new("recorded 3 blocks in 1 files\n")

      style("write_comment_baseline", { paths: word("lib/hecks/cli"), confirm: word(true) }, shell: shell)

      expect(shell.asked.first[:command]).to eq([tree.path("bin/standardize_comments"), "--write-baseline",
                                                 "lib/hecks/cli"])
    end
  end

  describe "a comment-only check" do
    it "compares each file's code with the ref, for lib unless paths are named" do
      shell = shell_class.new("code unchanged\n")

      expect(style("check_comments_unchanged", { ref: word("main") }, shell: shell)).to eq("code unchanged")
      expect(shell.asked.first[:command]).to eq([tree.path("bin/standardize_comments"), "--code-unchanged", "main",
                                                 "lib"])
    end

    it "refuses naming the file whose code changed" do
      shell = shell_class.new("lib/a.rb: code changed, not just comments\n", 1)

      expect { style("check_comments_unchanged", { ref: word("main") }, shell: shell) }
        .to raise_error(failure, "lib/a.rb: code changed, not just comments")
    end
  end

  describe "a report" do
    it "runs the linter's report with the options the query took" do
      shell = shell_class.new("summary\n")

      report = described_class.report("report_comments", { paths: "lib,spec", only: "long_line", json: true, top: 5 },
                                      tree, shell: shell)

      expect(report).to eq("summary")
      expect(shell.asked.first[:command]).to eq([tree.path("bin/standardize_comments"), "--report", "--only",
                                                 "long_line", "--json", "--top", "5", "lib", "spec"])
    end

    it "runs the Rust linter for the Rust report" do
      shell = shell_class.new("rust summary\n")

      described_class.report("report_rust_comments", { paths: "rust/src" }, tree, shell: shell)

      expect(shell.asked.first[:command].first(2)).to eq([tree.path("bin/standardize_comments_rust"), "--report"])
    end

    it "reads the real linter without touching the tree" do
      report = described_class.report("report_comments", { paths: "lib/hecks/canonical_json.rb", top: 1 }, tree)

      expect(report).not_to be_empty
    end
  end

  describe "canonicalise" do
    it "writes a JSON document with every object's keys sorted, recursively" do
      Dir.mktmpdir do |dir|
        file = File.join(dir, "doc.json")
        File.write(file, '{"b":1,"a":{"d":[{"z":1,"y":2}],"c":3}}')

        text = style("canonicalise", { file: word(file) })

        expect(text).to eq(JSON.pretty_generate("a" => { "c" => 3, "d" => [{ "y" => 2, "z" => 1 }] }, "b" => 1))
        expect(File.read(file)).to eq('{"b":1,"a":{"d":[{"z":1,"y":2}],"c":3}}')
      end
    end

    it "refuses a file that is not there, and a file that is not JSON" do
      Dir.mktmpdir do |dir|
        expect { style("canonicalise", { file: word(File.join(dir, "missing.json")) }) }
          .to raise_error(failure, /no such file/)
        File.write(File.join(dir, "bad.json"), "{")
        expect { style("canonicalise", { file: word(File.join(dir, "bad.json")) }) }
          .to raise_error(failure, /is not JSON/)
      end
    end
  end
end

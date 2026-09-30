require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/tools"
require_relative "../../support/fake_codebase_shell"
require "hecks/hecks/adapters/codebase/source_tree"

RSpec.describe Hecks::Adapters::Codebase::Style do
  let(:tree) { Hecks::Adapters::Codebase::Tree.new }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  # Answers a fixed output and status for every tool run, and remembers what was asked. The tools
  # run in this process, so what is stubbed is `Hecks::Tools.run`.
  def fake_tools(*answers)
    FakeCodebaseShell.new(*answers).tap do |shell|
      allow(Hecks::Tools).to receive(:run, &shell.method(:run_tool))
    end
  end

  def style(operation, held)
    described_class.call(operation, held, tree)
  end

  def word(value) = { value: value }

  describe "a check" do
    it "runs the Ruby linter in this process with --check on each path, from the checkout's root" do
      shell = fake_tools

      expect(style("check_comments", { paths: word("lib/a.rb,lib/b") })).to eq("no comment violations")
      expect(shell.asked.first[:command]).to eq(["standardize_comments", "--check", "lib/a.rb", "lib/b"])
      expect(shell.asked.first[:chdir]).to eq(tree.root)
    end

    it "limits the categories when only is named" do
      shell = fake_tools

      style("check_comments", { paths: word("lib"), only: word("long_line,all_caps") })

      expect(shell.asked.first[:command]).to eq(["standardize_comments", "--check", "--only",
                                                 "long_line,all_caps", "lib"])
    end

    it "refuses with every violation the linter listed" do
      fake_tools(["lib/a.rb:3: [long_line] 101 characters\n", 1])

      expect { style("check_comments", { paths: word("lib") }) }
        .to raise_error(failure, "lib/a.rb:3: [long_line] 101 characters")
    end

    it "runs the Rust linter for the Rust check" do
      shell = fake_tools

      style("check_rust_comments", { paths: word("rust/src") })

      expect(shell.asked.first[:command].first).to eq("standardize_comments_rust")
    end
  end

  describe "a fix" do
    it "lists the fixable violations and rewrites nothing unless confirmed" do
      shell = fake_tools(["lib/a.rb:3: [long_line] 101 characters\nlib/a.rb:9: [all_caps] SHOUT\n", 1])

      report = style("fix_comments", { paths: word("lib") })

      expect(report).to start_with("dry run, 2 violations a fix would rewrite (add --confirm to rewrite):")
      expect(shell.asked.map { |ask| ask[:command] })
        .to eq([["standardize_comments", "--check", "--only", "all_caps,long_bold,long_line", "lib"]])
    end

    it "says so when there is nothing to rewrite" do
      fake_tools

      expect(style("fix_rust_comments", { paths: word("rust") })).to eq("dry run: nothing a fix would rewrite")
    end

    it "rewrites with --fix when confirmed" do
      shell = fake_tools("rewrote 2 files\n")

      report = style("fix_comments", { paths: word("lib"), confirm: word(true) })

      expect(report).to eq("rewrote 2 files")
      expect(shell.asked.first[:command]).to eq(["standardize_comments", "--fix", "lib"])
    end
  end

  describe "the baseline" do
    it "lists the blocks it would record for lib/hecks, and writes nothing, unless confirmed" do
      shell = fake_tools(["lib/hecks/a.rb:4: [long_block] 14 lines\n", 1])

      report = style("write_comment_baseline", {})

      expect(report).to start_with("dry run, 1 blocks would be recorded as tolerated (add --confirm):")
      expect(shell.asked.first[:command]).to eq(["standardize_comments", "--check", "--only",
                                                 "long_block", "lib/hecks"])
    end

    it "records the blocks with --write-baseline when confirmed" do
      shell = fake_tools("recorded 3 blocks in 1 files\n")

      style("write_comment_baseline", { paths: word("lib/hecks/cli"), confirm: word(true) })

      expect(shell.asked.first[:command]).to eq(["standardize_comments", "--write-baseline",
                                                 "lib/hecks/cli"])
    end
  end

  describe "a comment-only check" do
    it "compares each file's code with the ref, for lib unless paths are named" do
      shell = fake_tools("code unchanged\n")

      expect(style("check_comments_unchanged", { ref: word("main") })).to eq("code unchanged")
      expect(shell.asked.first[:command]).to eq(["standardize_comments", "--code-unchanged", "main",
                                                 "lib"])
    end

    it "refuses naming the file whose code changed" do
      fake_tools(["lib/a.rb: code changed, not just comments\n", 1])

      expect { style("check_comments_unchanged", { ref: word("main") }) }
        .to raise_error(failure, "lib/a.rb: code changed, not just comments")
    end
  end

  describe "a report" do
    it "runs the linter's report with the options the query took" do
      shell = fake_tools("summary\n")

      report = described_class.report("report_comments", { paths: "lib,spec", only: "long_line", json: true, top: 5 },
                                      tree)

      expect(report).to eq("summary")
      expect(shell.asked.first[:command]).to eq(["standardize_comments", "--report", "--only",
                                                 "long_line", "--json", "--top", "5", "lib", "spec"])
    end

    it "runs the Rust linter for the Rust report" do
      shell = fake_tools("rust summary\n")

      described_class.report("report_rust_comments", { paths: "rust/src" }, tree)

      expect(shell.asked.first[:command].first(2)).to eq(["standardize_comments_rust", "--report"])
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

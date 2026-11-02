require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/command_names"

# The check reads text that shells out to the launcher and holds each name against the launcher's
# own name table. The table here is a small one standing in for `CliRunner.name_index`.
RSpec.describe Hecks::CommandNames do
  # The launcher's path, as a method so the text of this file holds no invocation of it.
  def launcher = "exe/hecks"

  def scopes
    commands = { "build.build_wasm" => "Build.build_wasm", "model_check_run.model_check" => "ModelCheckRun.model_check",
                 "console" => "console", "operation.run" => "Operation.run" }
    { ""       => { "command" => commands, "question" => { "workspace.status" => "Workspace.status", "config" => "config" },
              "modules" => ["deliver"] },
      "deploy" => { "command" => { "recipe.project" => "Recipe.project" }, "question" => {}, "modules" => [] } }
  end

  let(:root) { Dir.mktmpdir("command-names") }

  after { FileUtils.remove_entry(root) }

  define_method(:write) do |path, text|
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), text)
  end

  define_method(:found) { Hecks::CommandNames::Check.findings(root: root, scopes: scopes).map(&:to_s) }
  define_method(:problem) { |*words| Hecks::CommandNames::Index.new(scopes).problem(words) }

  describe "a dead name" do
    before { write(".github/workflows/ci.yml", "jobs:\n  a:\n    run: bundle exec #{launcher} model_check --wait\n") }

    it "is reported as file:line with the string" do
      expect(found.first).to start_with(".github/workflows/ci.yml:3: run: bundle exec #{launcher} model_check --wait")
    end

    it "is given the nearest valid name" do
      expect(found.first).to end_with("nearest valid name: ModelCheckRun.model_check!")
    end
  end

  describe "a regex that matches a command line" do
    before { write("spec/a_spec.rb", "match = line.match(%r{\\Abundle exec #{launcher} gate_run\\.gate! stage=ci})\n") }

    it "is a pattern, not a launcher call" do
      expect(found).to be_empty
    end
  end

  describe "the spellings the launcher accepts" do
    accepted = ["Build.build_wasm!", "Hecks::Build.build_wasm!", "Hecks::Build.BuildWasm!", "build.build_wasm!",
                "query workspace.status", "workspace.status", "ask Workspace.status", "config", "console!", "usage",
                "deliver", "deploy recipe.project!", "deploy Recipe.project!"]

    accepted.each do |spelling|
      it "passes #{spelling}" do
        expect(problem(*spelling.split)).to be_nil
      end
    end
  end

  describe "the bang rule" do
    it "refuses a command written without its !" do
      expect(problem("build.build_wasm").text).to include("is a command and writes")
    end

    it "refuses a read written with a !" do
      expect(problem("workspace.status!").text).to include("is a query and reads")
    end

    it "suggests the banged name for a command" do
      expect(problem("Build.build_wasm").nearest).to eq("Build.build_wasm!")
    end

    it "refuses a command asked as a query" do
      expect(problem("query", "operation.run").text).to include("is a command, not a query")
    end
  end

  describe "text that is shown and not run" do
    let(:dead) { "#{launcher} model_check" }

    before do
      write("docs/decisions/0001-x.md", "run #{dead}\n")
      write("docs/implemented/decisions/0002-y.md", "run #{dead}\n")
      write("CHANGELOG.md", "- ran `#{dead}`\n")
      write("docs/implemented/guides/old.md", "**Historical snapshot**\n\nrun `#{dead}`\n")
      write("docs/implemented/guides/page.md", "<!-- dead-name-check: skip-file -->\n\n`#{dead}`\n")
    end

    it "is left out when it is a decision, the changelog or a snapshot" do
      expect(found).to be_empty
    end

    it "is left out in a fence marked skip, historical or illustrative", :aggregate_failures do
      %w[skip historical illustrative].each do |word|
        write("docs/implemented/guides/#{word}.md", "```sh #{word}\n#{dead}\n```\n")
      end

      expect(found).to be_empty
    end

    it "is left out on a line that carries the marker" do
      write("spec/shown_spec.rb", "# dead-name-check: skip\nSHOWN = \"#{dead}\"\n")

      expect(found).to be_empty
    end

    it "is reported when nothing excuses it" do
      write("docs/implemented/guides/live.md", "```sh\n#{dead}\n```\n")

      expect(found.first).to start_with("docs/implemented/guides/live.md:2:")
    end
  end

  describe "where it looks" do
    it "reads a Ruby backtick call and a gate row's argv", :aggregate_failures do
      write("spec/a_spec.rb", "out = `#{launcher} stale_name`\n")
      write("lib/hecks/language/bluebook/vocabulary.bluebook", "argv: \"bundle exec #{launcher} gone.thing --wait\",\n")

      files = found.map { |line| line[/\A[^:]+/] }

      expect(files).to contain_exactly("spec/a_spec.rb", "lib/hecks/language/bluebook/vocabulary.bluebook")
    end

    it "ignores prose in a Ruby comment that names the launcher without its path" do
      # dead-name-check: skip
      write("spec/b_spec.rb", "# `hecks stale_name` is what this once ran\n")

      expect(found).to be_empty
    end

    it "ignores a plain English word after a bare hecks" do
      write("docs/implemented/guides/prose.md", "Then `hecks journals` to the store.\n")

      expect(found).to be_empty
    end
  end

  describe "the places a Ruby string, a QA script or an agent file names a launcher command" do
    {
      "lib/hecks/tools/hint.rb"   => "warn \"run `%<l>s gone_command` to fix\"\n",
      "qa/run.sh"                 => "%<l>s gone_command --wait\n",
      ".claude/skills/x/SKILL.md" => "Run `%<l>s gone_command`.\n",
      ".claude/hooks/h.sh"        => "%<l>s gone_command\n",
      "scripts/go.sh"             => "%<l>s gone_command\n"
    }.each do |path, template|
      it "goes red for a nonexistent command in #{path}, naming file:line" do
        write(path, format(template, l: launcher))

        expect(found.map { |line| line[/\A[^:]+:\d+/] }).to eq(["#{path}:1"])
      end

      it "stays green for a real command in #{path}" do
        write(path, format(template, l: launcher).sub("gone_command", "workspace.status"))

        expect(found).to be_empty
      end
    end

    it "does not read a checkout's linked worktrees under .claude/worktrees" do
      write(".claude/worktrees/other/lib/a.rb", "# #{launcher} gone_command\n")

      expect(found).to be_empty
    end

    it "excuses a line only by an exact allowed string" do
      write("lib/a.rb", "x = \"#{launcher} Maintenance.mint_era! run.value=<run-id>\"\n")
      write("lib/b.rb", "x = \"#{launcher} Maintenance.other!\"\n")

      expect(found.map { |line| line[/\A[^:]+/] }).to eq(["lib/b.rb"])
    end
  end

  describe ".check" do
    it "raises with every finding" do
      write("Makefile", "go:\n\t#{launcher} stale_name\n")
      allow(Hecks::Adapters::Driving::CliRunner).to receive(:name_index).and_return(scopes)

      expect { described_class.check(root: root, runtime: double) }.to raise_error(described_class::Failure, /Makefile:2:/)
    end
  end
end

require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/command_names"

# ADR 0190 point 7: a refusal names its remedy as a command, and every remedy a Ruby refusal or a
# Rust host refusal names resolves to a command a person or an agent runs. The table here is a
# small one standing in for `CliRunner.name_index`; the last group holds this checkout to the rule.
RSpec.describe Hecks::CommandNames::Remedies do
  # The launcher's path, as a method so the text of this file holds no invocation of it.
  def launcher = "exe/hecks"

  def scopes
    commands = { "build.project_rust" => "Build.project_rust", "release.tag" => "Release.tag" }
    questions = { "schema_revision.audit_translation" => "SchemaRevision.audit_translation" }
    { "" => { "command" => commands, "question" => questions, "modules" => [] } }
  end

  let(:root) { Dir.mktmpdir("remedy-names") }

  after { FileUtils.remove_entry(root) }

  define_method(:write) do |path, text|
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), text)
  end

  define_method(:found) do
    described_class.findings(root: root, scopes: scopes, record_only: ["Release.tag"]).map(&:to_s)
  end

  describe "a stale remedy in a Ruby refusal" do
    before { write("lib/a.rb", "raise Failure, \"no module — run hecks project_rust first\"\n") }

    it "fails by file:line, naming the nearest command" do
      expect(found).to eq(["lib/a.rb:1: raise Failure, \"no module — run hecks project_rust first\" -- " \
                           "project_rust is not a command or query; nearest valid name: Build.project_rust!"])
    end
  end

  describe "a stale remedy in a Rust host refusal string" do
    before { write("rust/host/src/boot.rs", "    \"then check it with hecks audit_translation\",\n") }

    it "fails by file:line" do
      expect(found.first).to start_with("rust/host/src/boot.rs:1: ")
    end
  end

  describe "a remedy that names a record's own command" do
    before { write("lib/a.rb", "warn \"run hecks Release.tag! to fix it\"\n") }

    it "fails, since a person or an agent cannot run it" do
      expect(found.first).to end_with("Release.tag! is a record's own command; a refusal names one a person or an agent runs")
    end
  end

  describe "text that is not a remedy" do
    lines = ["warn \"run hecks Build.project_rust! domain.value=x\"",
             "program: \"hecks run\"", "USAGE = \"usage: hecks quality_control tick\"",
             "# run hecks project_rust in a comment", "\"hecks fuzz found a bug\""]

    lines.each do |line|
      it "passes #{line}" do
        write("lib/a.rb", "#{line}\n")
        expect(found).to be_empty
      end
    end
  end

  describe "a Rust host string that names the launcher's path" do
    before { write("rust/host/src/api.rs", "    .expect(\"bundle exec #{launcher} project_rust first\")\n") }

    it "is read as a remedy" do
      expect(found.size).to eq(1)
    end
  end

  describe "this checkout" do
    let(:checkout) { File.expand_path("..", __dir__) }

    it "names only remedies that resolve to a command a person or an agent runs" do
      runtime = Hecks.describe(File.join(checkout, "lib/hecks/hecks"))
      expect { Hecks::CommandNames.check_remedies(root: checkout, runtime: runtime) }.not_to raise_error
    end
  end
end

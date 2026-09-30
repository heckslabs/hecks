require "spec_helper"
require "yaml"

# docs/tools.md lists, for each bin/ script, the launcher form `exe/hecks` executes. Those forms
# live in lib/hecks/three_zero/forms.yml; this pins the document to that file so the two cannot
# drift, and pins that the QualityControl scripts are listed as commands.
RSpec.describe "docs/tools.md" do
  let(:doc_path) { File.join(InMemoryDomain::ROOT, "docs/tools.md") }
  let(:forms) { YAML.load_file(File.join(InMemoryDomain::ROOT, "lib/hecks/three_zero/forms.yml")) }
  let(:rows) do
    File.readlines(doc_path, chomp: true, encoding: "UTF-8")
        .filter_map { |line| line.match(%r{\A\| (.*) \| `bin/([^`]+)` \|\z})&.captures }
        .to_h { |cell, script| [script, cell.delete("`").gsub("\\|", "|")] }
  end

  it "gives every bin/ script the form forms.yml holds for it" do
    expect(rows.reject { |script, form| forms[script] == form }).to eq({})
  end

  it "lists every script forms.yml knows, the qa_* ones included" do
    expect(forms.keys - rows.keys).to eq([])
  end

  it "does not say the qa_* scripts are not commands" do
    expect(File.read(doc_path, encoding: "UTF-8")).not_to include("are not commands yet")
  end
end

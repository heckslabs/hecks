require "spec_helper"
require "hecks/tools/tools_doc"

# docs/tools.md lists, for each bin/ script, the launcher form `exe/hecks` executes. The tables are
# written by `hecks project_tools_doc` from the RetiredScript rows and each command's own arguments;
# this pins the document to what the rows render, so a command whose arguments changed with no
# regenerated doc fails here, and pins that the QualityControl scripts are listed as commands.
RSpec.describe "docs/tools.md" do
  let(:root)     { InMemoryDomain::ROOT }
  let(:doc_path) { File.join(root, "docs/tools.md") }
  let(:text)     { File.read(doc_path, encoding: "UTF-8") }
  let(:tool)     { Hecks::Tools::ToolsDoc }

  it "holds exactly the tables the RetiredScript rows render" do
    expect(tool.projection(text, root)).to eq(text)
  end

  it "has a marked table for every section the rows name" do
    sections = tool.rows.map { |row| row["section"] }.uniq

    expect(sections - tool::SECTIONS).to eq([])
    expect(tool::SECTIONS.reject { |section| text.include?("generated:begin tools section=#{section} -->") }).to eq([])
  end

  it "lists every retired script, the qa_* ones included, once" do
    listed = text.lines.filter_map { |line| line[%r{\| `bin/([^`]+)` \|\s*\z}, 1] }
    scripts = tool.rows.map { |row| row["script"] }.uniq - ["(new)"]

    expect(scripts - listed).to eq([])
    expect(listed.tally.select { |_, count| count > 1 }.keys).to eq([])
  end

  it "does not say the qa_* scripts are not commands" do
    expect(text).not_to include("are not commands yet")
  end
end

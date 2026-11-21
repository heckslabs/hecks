# frozen_string_literal: true

require_relative "../support/session_line_words"

# The model is the role file's, read by Claude Code once at launch; the launcher names none.
RSpec.describe Hecks::Adapters::SessionLine, "#arguments" do
  include SessionLineWords

  let(:checkout) { McpSelectionCheckout.build }

  after { FileUtils.remove_entry(checkout) }

  it "declares sonnet in coder.md and passes no --model", :aggregate_failures do
    expect(File.read(File.join(Dir.pwd, ".claude/agents/coder.md"))).to match(/^model: sonnet$/)
    expect(words(works_as: "coder")).not_to include("--model")
  end

  it "asks the credential setting about the resolved role" do
    words(works_as: "coder")
    expect(scrubbing.roles).to eq(["coder"])
  end
end

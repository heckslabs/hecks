# frozen_string_literal: true

require "spec_helper"
require "hecks/tools"

Hecks::Tools.fetch("stub_scope")

RSpec.describe "Hecks::Tools::StubScope" do
  let(:tool) { Hecks::Tools.fetch("stub_scope") }

  def grep_line(path, line, text) = "HEAD:#{path}:#{line}:#{text}"

  describe ".find" do
    it "reads the finding key from a Ruby comment marker" do
      stubs = tool.find([grep_line("lib/a.rb", 3, "  # hecks-stub: dc-main")])

      expect(stubs.map { |s| [s.path, s.line, s.key] }).to eq([["lib/a.rb", 3, "dc-main"]])
    end

    it "reads a Rust marker" do
      stubs = tool.find([grep_line("src/a.rs", 9, "    // hecks-stub: BUG-152")])

      expect(stubs.map(&:key)).to eq(["BUG-152"])
    end

    it "flags a marker that names no finding" do
      stubs = tool.find([grep_line("lib/a.rb", 1, "# hecks-stub:")])

      expect(stubs.first.to_s).to include("names no finding")
    end

    it "leaves out the files that define the marker" do
      stubs = tool.find([grep_line("lib/hecks/tools/stub_scope.rb", 1, "# hecks-stub: x")])

      expect(stubs).to be_empty
    end

    it "ignores text that is not a marker comment" do
      expect(tool.find([grep_line("lib/a.rb", 1, "x = 'hecks-stub: nope'")])).to be_empty
    end
  end
end

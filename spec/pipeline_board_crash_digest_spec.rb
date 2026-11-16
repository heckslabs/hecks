# frozen_string_literal: true

require "spec_helper"
require "open3"
require "hecks/pipeline_board/adapters/crash_digest"

# A crashed board's log reduces to one line, and the board's restart code loads the way the watchdog
# starts it: under `--disable-gems`, with no `lib` on the load path.
RSpec.describe Hecks::Adapters::PipelineBoard::CrashDigest do
  let(:report) do
    "noise\n/x/lib/hecks/pipeline_board/adapters/pipeline_web/server.rb:78: [BUG] Segmentation fault at 0x6\n" \
      "ruby 3.3.7 (2025-01-15 revision be31f993d7) [arm64-darwin24]\n\n-- Crash Report\n"
  end

  it "names the fault, the place and the interpreter" do
    expect(described_class.line(report)).to eq(
      "Segmentation fault at 0x6 at lib/hecks/pipeline_board/adapters/pipeline_web/server.rb:78 (ruby 3.3.7)"
    )
  end

  it "answers nil when the log holds no report" do
    expect(described_class.line("listening\n")).to be_nil
  end

  it "loads the board restart code without gems or a load path", :aggregate_failures do
    file = File.expand_path("../lib/hecks/pipeline_board/adapters/board_restart.rb", __dir__)
    out, status = Open3.capture2e(RbConfig.ruby, "--disable-gems", "-e", "require #{file.inspect}; puts :loaded")
    expect(out).to include("loaded")
    expect(status).to be_success
  end
end

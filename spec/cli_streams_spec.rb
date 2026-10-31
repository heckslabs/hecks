require "spec_helper"
require "stringio"
require_relative "../lib/hecks/tools/project_diagrams"

# A message a person reads is on standard error; the result is on standard output, so a pipe
# through `jq` never receives a warning (ADR 0163, step 29), and no status line carries escape bytes
# (step 34).
RSpec.describe "launcher status lines" do
  def capture
    out = StringIO.new
    err = StringIO.new
    saved = [$stdout, $stderr]
    $stdout = out
    $stderr = err
    yield
    [out.string, err.string]
  ensure
    $stdout, $stderr = saved
  end

  def diagrams_notice
    capture { Hecks::Tools::ProjectDiagrams.report("Pizza", "/tmp/none", []) }
  end

  it "sends the no-lifecycle notice to standard error" do
    expect(diagrams_notice.last).to include("Pizza declares no lifecycle")
  end

  it "keeps the no-lifecycle notice off standard output" do
    expect(diagrams_notice.first).to be_empty
  end

  it "writes no escape bytes to a stream that is not a terminal" do
    expect(diagrams_notice.join).not_to include("\e[")
  end

  it "writes no escape bytes when NO_COLOR is set" do
    saved = ENV.fetch("NO_COLOR", nil)
    ENV["NO_COLOR"] = "1"
    expect(diagrams_notice.join).not_to include("\e[")
  ensure
    ENV["NO_COLOR"] = saved
  end
end

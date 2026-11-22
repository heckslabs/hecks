# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

# The MCP server's stdio entry is a thin client of the control process: it asks the resident to
# serve the session and loads no domain of its own, and it serves cold, saying so, when none
# answers. Each case runs the entry in a subprocess so what it loads is its own.
RSpec.describe "the MCP stdio entry as a client of the control process" do
  let(:lib) { File.expand_path("../lib", __dir__) }
  let(:entry) { "hecks/adapters/driving/mcp/stdio_entry" }

  def run_entry(prelude, argv: "[\"--stdio\"]")
    code = "#{prelude}\nrequire '#{entry}'\n" \
           "Hecks::Adapters::Driving::Mcp.serve_stdio(#{argv})"
    Open3.capture3(RbConfig.ruby, "-I", lib, "-e", code, stdin_data: "")
  end

  let(:answered) do
    <<~RUBY
      require "hecks/adapters/driving/resident/client"
      Hecks::Adapters::Driving::Resident::Client.define_singleton_method(:ask) { |*_a, **_k| [0, nil] }
      at_exit { puts "LOADED=\#{$LOADED_FEATURES.grep(/driving\\/mcp\\.rb\\z/).size}" }
    RUBY
  end

  let(:silent) do
    <<~RUBY
      require "hecks/adapters/driving/resident/client"
      Hecks::Adapters::Driving::Resident::Client.define_singleton_method(:ask) { |*_a, **_k| [nil, nil] }
    RUBY
  end

  it "ends with the status the control process gave, loading no MCP server of its own" do
    out, _err, status = run_entry(answered)
    expect([status.exitstatus, out]).to eq([0, "LOADED=0\n"])
  end

  it "serves cold and says so on stderr when no control process answers" do
    _out, err, status = run_entry(silent)
    expect([status.exitstatus, err]).to match([0, /control process down, running cold/])
  end

  it "refuses a transport that is not stdio, as it does without a control process" do
    _out, err, status = run_entry(answered, argv: "[\"--port\", \"3000\"]")
    expect([status.exitstatus, err]).to match([2, /hecks-mcp/])
  end
end

# frozen_string_literal: true

require "spec_helper"
require "hecks/adapters/driving/resident/client"

# The long-running servers the launcher runs itself, never as a resident's child.
RSpec.describe Hecks::Adapters::Driving::Resident::Client do
  def serving?(*argv)
    stub_const("ARGV", argv)
    described_class.serving?
  end

  ["Server.present!", "Hecks::Server.present!", "server.present", "Server.serve_query_ir_mcp!"].each do |word|
    it "runs #{word} itself" do
      expect(serving?(word, "port=4747", "--wait")).to be(true)
    end
  end

  it "leaves a command that ends to the resident" do
    expect(serving?("Server.complete")).to be(false)
  end

  it "names the Hecks domain's Server.Present command, which the bypassed line boots and runs", :aggregate_failures do
    source = File.read(File.expand_path("../lib/hecks/hecks/serve/serve.bluebook", __dir__))
    expect(source[/aggregate "Server".*?\n    end\n/m]).to include('command "Present" do')
    expect(described_class::SERVING).to include("server.present")
  end
end

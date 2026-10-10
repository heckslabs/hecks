require "spec_helper"

RSpec.describe "the spellings removed in 3.4.0, and the door spellings after them" do
  it "no longer defines Hecks::Facade, Hecks::Doors or Hecks::Doors::Surface", :aggregate_failures do
    expect(Hecks.const_defined?(:Facade, false)).to be false
    expect(Hecks.const_defined?(:Doors, false)).to be false
  end

  it "refuses the install_facade: and install_doors: keywords on every boot entry point", :aggregate_failures do
    %i[install_facade install_doors].each do |keyword|
      expect { Hecks.boot("nowhere", keyword => false) }.to raise_error(ArgumentError, /#{keyword}/)
      expect { Hecks.boot_files([], keyword => false) }.to raise_error(ArgumentError, /#{keyword}/)
      expect { Hecks.boot_described(nil, keyword => false) }.to raise_error(ArgumentError, /#{keyword}/)
    end
  end

  it "refuses a HECKS_DOOR_ variable instead of starting an unrestricted MCP server" do
    scope = Hecks::Adapters::Driving::McpScope
    expect { scope.from_env("HECKS_DOOR_TOOLS" => "readers") }.to raise_error(ArgumentError, /HECKS_SERVER_TOOLS/)
  end
end

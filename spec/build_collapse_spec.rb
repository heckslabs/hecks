require "spec_helper"

# The collapsed `Build.build! what=` (ADR 0163 step 55): its kinds are closed, and the hecksagon
# binds each kind to the port operation that does its work. Routing is covered by
# packing_value_routing_spec.
RSpec.describe "Build.build, bound by kind" do
  let(:bluebook) { File.join(InMemoryDomain::ROOT, "lib/hecks/hecks/build/build.bluebook") }
  let(:hecksagon) { File.join(InMemoryDomain::ROOT, "lib/hecks/hecks/hecks.hecksagon") }

  it "declares one build command with a closed kind" do
    expect(File.read(bluebook)).to include('command "Build" do', "one_of: %w[host wasm browser parser]")
  end

  it "binds the wasm kind to the wasm operation" do
    expect(File.read(hecksagon)).to include('asks "Wasm"', 'handles "Build.build!", value: "wasm"')
  end

  it "binds the host kind to the host operation" do
    expect(File.read(hecksagon)).to include('asks "Host"', 'handles "Build.build!", value: "host"')
  end

  it "binds the browser kind to the browser operation" do
    expect(File.read(hecksagon)).to include('asks "BrowserWasm"', 'handles "Build.build!", value: "browser"')
  end

  it "binds the parser kind to the parser operation" do
    expect(File.read(hecksagon)).to include('asks "Parser"', 'handles "Build.build!", value: "parser"')
  end
end

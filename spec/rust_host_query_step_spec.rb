require "spec_helper"
require "open3"

# The Rust host's wire takes a query step (`{"query": "Aggregate.Query", "args": {...}}`). A
# declared query that filters stored records is the kernel's to answer; a query that `returns` a
# value object is answered from outside the domain and the host binds no adapter, so it refuses
# in the words Ruby's own refusals use. rust/host/src/query_step.rs pins the routing decision
# against a hand-written IR; this spec pins the wording against Ruby's.
RSpec.describe "Rust host query step", :io do
  QUERY_STEP_HOST_DIR = File.expand_path("../rust/host", __dir__)

  it "words an undeclared query exactly as the Ruby runtime does" do
    ruby = Hecks::Runtime::RefusalWording.render_site("UnknownVerb", "no_query",
                                                      aggregate: "Ledger", query: "Nope")

    expect(ruby).to eq('Ledger has no query "Nope"')
    expect(File.read(File.join(QUERY_STEP_HOST_DIR, "src", "query_step.rs"))).to include('Ledger has no query \"Nope\"')
  end

  it "refuses an outside-answered query with the tail Ruby's adapter lookup ends on" do
    ruby = begin
      Hecks::Runtime::AdapterLookup.adapter_class(Struct.new(:adapters).new({}), "Echoer", asked: "Note.Echo")
    rescue Hecks::Runtime::WiringError => e
      e.message
    end

    expect(ruby).to end_with("nothing can answer Note.Echo")
    source = File.read(File.join(QUERY_STEP_HOST_DIR, "src", "query_step.rs"))
    expect(source).to include("answered outside the domain").and include("nothing can answer {short}")
  end

  it "routes derivable queries to the kernel and refuses outside-answered ones (cargo unit tests)" do
    stdout, stderr, status = Open3.capture3("cargo", "test", "--bin", "bootstrap", "query_step", chdir: QUERY_STEP_HOST_DIR)

    expect(status).to be_success, "cargo test failed:\n#{stdout}\n#{stderr}"
    expect(stdout).to match(/test result: ok\. 5 passed/)
  end
end

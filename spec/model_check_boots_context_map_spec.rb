require "spec_helper"
require "hecks/tools/model_check"

# `model_check` boots each source into a registry of its own. That boot reads the source's context
# map with its bluebooks and hecksagons, so the declared relationships and the cycles a map accepts
# are checked by `model_check` itself and not only by a spec (ADR 0135, ADR 0207).
RSpec.describe "The context map model_check boots with a source" do
  let(:tool) { Object.new.extend(Hecks::Tools::ModelCheck::Sources) }
  let(:root) { File.expand_path("..", __dir__) }

  it "loads the map beside a directory's bluebooks" do
    registry = tool.boot(File.join(root, "examples/banking/bluebook"))
    expect(registry.context_maps.map(&:name)).to eq(["Banking"])
  end

  it "loads the Hecks domain's map, with the cycles it accepts" do
    maps = tool.boot(File.join(root, "lib/hecks/hecks")).context_maps
    expect(Hecks::Bluebook::ModelCheck.accepted_cycles(maps).keys).to include(%w[Agents Hecks])
  end

  it "holds no map for a source that declares none" do
    expect(tool.boot(File.join(root, "examples/chess/bluebook")).context_maps).to be_empty
  end
end

require "spec_helper"

# `describe` answers with the directory at once and loads the declarations the first time the
# registry is asked for, so a launcher with its help remembered never loads them.
RSpec.describe "Hecks.describe" do
  let(:path) { File.join(InMemoryDomain::ROOT, "examples/pizzas") }

  it "names the directory without loading the declarations" do
    described = Hecks.describe(path)

    expect(described.directory).to end_with("pizzas/bluebook")
    expect(described.instance_variable_get(:@registry)).to be_nil
  end

  it "loads the declarations on the first registry call and keeps them" do
    described = Hecks.describe(path)
    registry = described.registry

    expect(registry.bluebook("Pizzas")).not_to be_nil
    expect(described.registry).to equal(registry)
  end

  it "still refuses a directory that is not there at once" do
    expect { Hecks.describe(File.join(path, "no-such-domain")) }.to raise_error(Errno::ENOENT)
  end
end

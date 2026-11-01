require "spec_helper"
require "hecks/command_names"
require "hecks/workflow_pagination"

# The two text checks held against this checkout: the gate runs the same on every push, and this
# keeps a name the launcher dropped, or a list counted from its first page, from coming back.
RSpec.describe "this checkout's launcher names and workflow list calls" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:runtime) { Hecks.describe(File.join(root, "lib/hecks/hecks")) }

  it "has no workflow that counts a GitHub list from its first page" do
    expect(Hecks::WorkflowPagination.findings(root)).to be_empty
  end

  it "invokes only launcher names the launcher accepts", :io do
    expect { Hecks::CommandNames.check(root: root, runtime: runtime) }.not_to raise_error
  end

  it "indexes every name the launcher lists", :io do
    scope = Hecks::Adapters::Driving::CliRunner.name_index(runtime: runtime).fetch("")
    listed = Hecks::Adapters::Driving::CliRunner.known_names(runtime: runtime)

    expect(listed - scope["command"].keys - scope["question"].keys).to be_empty
  end
end

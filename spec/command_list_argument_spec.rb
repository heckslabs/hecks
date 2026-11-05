require "spec_helper"

# The refusals of a command's `list_of` argument live in
# examples/command_list_argument/bluebook/command_list_argument.behaviors. What stays here is what
# `expect` cannot say: the size of the aggregate's own list after `append:`/`remove:` take one
# element by design.
RSpec.describe "a command's list_of argument" do
  let(:runtime) do
    path = File.join(InMemoryDomain::ROOT, "examples/command_list_argument/bluebook/command_list_argument.bluebook")
    Hecks.boot_files([path], install_driving: false)
  end

  it "keeps the single-element form for the append and remove effects", :aggregate_failures do
    runtime.dispatch("Binder::Folder.Open", with: { name: { value: "f" }, labels: [] })
    id = "f"
    runtime.dispatch("Binder::Folder.Attach", to: id, with: { label: "x" })
    two = runtime.dispatch("Binder::Folder.Attach", to: id, with: { label: "y" })
    one = runtime.dispatch("Binder::Folder.Detach", to: id, with: { label: "x" })

    expect([two, one].map { |result| result.state[:labels].size }).to eq([2, 1])
  end
end

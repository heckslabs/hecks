require "spec_helper"

# The ids a command's result names: the run key, the record written, and the references it used.
RSpec.describe Hecks::Adapters::Driving::CliRunner::RunReference do
  def named(**values) = values.transform_values { |value| { value: value } }

  describe ".ids" do
    it "names the run, the record written, and the references the command used" do
      ids = described_class.ids(named(run: "r1", from: "ids-1", checkout: "/c", branch: "b"), "rec-1")

      expect(ids).to eq(run: "r1", from: "ids-1", checkout: "/c", branch: "b", id: "rec-1")
    end

    it "leaves out the ids a command did not use" do
      expect(described_class.ids(named(branch: "b"), nil)).to eq(branch: "b")
    end
  end
end

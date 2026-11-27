# frozen_string_literal: true

require "spec_helper"

# No bluebook or hecksagon in Hecks speaks GitHub's REST field names: the GitHub edge moved out with
# the development pipeline (ADR 0205), and what stays reads GitHub only through adapters behind ports.
RSpec.describe "the GitHub REST edge" do
  let(:root)   { File.expand_path("..", __dir__) }
  let(:fields) { /head_ref|merged_at|x-ratelimit|http_status|check_runs/i }

  it "keeps GitHub's REST field names out of every bluebook and hecksagon" do
    declared = Dir.glob(File.join(root, "lib/**/*.{bluebook,hecksagon}"))
    expect(declared.select { |path| File.read(path).match?(fields) }).to eq([])
  end
end

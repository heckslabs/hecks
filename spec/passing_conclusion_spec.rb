require "spec_helper"

# What counts as a passing CI conclusion is one table in the language, `PassingConclusion`. Every
# reader of a run, job or check run takes it from there, so a promotion, the red flag, the pipeline
# board, CI speed and the release-only check cannot disagree about a `neutral` result.
RSpec.describe "The passing CI conclusions" do
  READERS = %w[
    lib/hecks/quality_control/adapters/github_checks.rb
    lib/hecks/hecks/adapters/ci_runs.rb
    lib/hecks/hecks/adapters/red_flag_survey.rb
    lib/hecks/pipeline_board/adapters/pipeline_github/runs.rb
    lib/hecks/tools/release_only.rb
    lib/hecks/ci_speed/adapters/ci_reader.rb
  ].freeze

  def source(path) = File.read(File.expand_path("../#{path}", __dir__))

  it "states what GitHub counts as passed for a required check" do
    expect(Hecks::Vocabulary.fetch("PassingConclusion")).to eq(%w[success neutral skipped])
  end

  READERS.each do |path|
    it "is read by #{path}" do
      expect(source(path)).to include('Hecks::Vocabulary.fetch("PassingConclusion")')
    end

    it "is not listed again in #{path}" do
      expect(source(path)).not_to include("%w[success")
    end
  end
end

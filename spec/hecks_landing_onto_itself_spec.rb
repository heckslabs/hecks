require "hecks"

# A branch never lands onto itself: the bluebook's Landing.Land and Landing.Finish givens refuse
# it before any git state is read. Only the refusal is exercised here: an accepted dispatch would
# run the landing reaction against the real checkout. The adapter keeps the check for a branch it
# finds current.
RSpec.describe "Landing refuses a branch that lands onto itself" do
  def dispatcher
    @dispatcher ||= Hecks.boot(File.expand_path("../lib/hecks/hecks", __dir__))
  end

  def args(branch:, onto:)
    { run: { value: "landing-onto-itself" }, branch: { value: branch }, onto: { value: onto }, confirm: { value: true } }
  end

  %w[Hecks::Landing.Land Hecks::Landing.Finish].each do |command|
    it "refuses #{command} when the branch is the branch it lands onto" do
      expect { dispatcher.dispatch_flat(command, **args(branch: "work/a", onto: "work/a")) }
        .to raise_error(Hecks::Runtime::GivenNotMet, /never lands onto itself/)
    end
  end
end

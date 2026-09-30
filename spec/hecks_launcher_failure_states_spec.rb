require "spec_helper"

# `--wait` exits 1 only for a lifecycle state the launcher setting lists as a failure. The language
# has no failure marker on a state, so the list is checked against the states the chapters declare:
# a state named like a failure that is not listed would let a failed run exit 0.
RSpec.describe "the launcher's failure states" do
  # Words that make a lifecycle state read as a failure.
  FAILURE_NAMED = /fail|fault|flag|drift|unreach|refus|halt|stop|abandon|\Ared\z|needs_fix|error|broken/

  before(:all) do
    @runtime = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_facade: false)
  end

  def listed(chapter) = Array(Hecks::Facade::LauncherOptions.settings(@runtime, chapter)&.fetch(:failure_states, nil))

  def declared
    @runtime.registry.bluebooks.flat_map do |name, chapter|
      chapter.aggregates.filter_map do |aggregate|
        [name, aggregate.hecks_name, aggregate.lifecycle.states] if aggregate.lifecycle
      end
    end
  end

  it "lists every lifecycle state named like a failure, in every chapter" do
    unlisted = declared.flat_map do |chapter, aggregate, states|
      states.grep(FAILURE_NAMED).map(&:to_s).reject { |state| listed("Hecks").include?(state) }
            .map { |state| "#{chapter}::#{aggregate} #{state}" }
    end

    expect(unlisted).to eq([])
  end

  it "names the states the Door, Sweep and Clearance lifecycles end in" do
    expect(listed("Hecks")).to include("stopped", "abandoned", "red")
  end

  it "gives the attached Deploy chapter the same list" do
    expect(listed("Deploy")).to eq(listed("Hecks"))
  end

  it "lists no state that no lifecycle declares" do
    every = declared.flat_map { |_, _, states| states.map(&:to_s) }

    expect(listed("Hecks") - every).to eq([])
  end
end

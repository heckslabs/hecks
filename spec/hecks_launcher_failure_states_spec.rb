require "spec_helper"

# `--wait` exits 1 only for a state its lifecycle marks `:failure` (ADR 0097). The language cannot
# tell a failure by its name, so this checks the chapters' marks against the states they declare:
# a state named like a failure that is not marked would let a failed run exit 0.
RSpec.describe "the lifecycle failure marks" do
  # Words that make a lifecycle state read as a failure.
  FAILURE_NAMED = /fail|fault|flag|drift|unreach|refus|halt|stop|abandon|\Ared\z|needs_fix|error|broken/

  before(:all) do
    @runtime = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  def declared
    @runtime.registry.bluebooks.flat_map do |name, chapter|
      chapter.aggregates.filter_map do |aggregate|
        [name, aggregate.hecks_name, aggregate.lifecycle] if aggregate.lifecycle
      end
    end
  end

  def unmarked_failures(chapter, aggregate, lifecycle)
    marked = Array(lifecycle.marked(Hecks::Adapters::Driving::LauncherOptions::FAILURE_MARK))
    lifecycle.states.map(&:to_s).grep(FAILURE_NAMED).reject { |state| marked.include?(state) }
             .map { |state| "#{chapter}::#{aggregate} #{state}" }
  end

  it "marks every lifecycle state named like a failure, in every chapter" do
    expect(declared.flat_map { |row| unmarked_failures(*row) }).to eq([])
  end

  it "marks the states the Launch, Sweep and Clearance lifecycles end in" do
    ends   = { "Launch" => "stopped", "Sweep" => "abandoned", "Clearance" => "red" }
    marked = declared.to_h { |_, aggregate, lifecycle| [aggregate, Array(lifecycle.marked("failure"))] }

    expect(ends.reject { |aggregate, state| marked[aggregate].include?(state) }).to eq({})
  end

  it "keeps the failure list off every chapter's launcher setting" do
    %w[Hecks Deploy Site].each do |chapter|
      expect(Hecks::Adapters::Driving::LauncherOptions.settings(@runtime, chapter)&.key?(:failure_states)).not_to be(true)
    end
  end
end

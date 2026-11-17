require "spec_helper"

# Which landing refusals plan their work item again: the `where` of the Hecks hecksagon's
# `FindWorkWhenTheJobsLandingIsRefused` translation, whose opening words are the contract with the
# adapters that raise them.
RSpec.describe "FindWorkWhenTheJobsLandingIsRefused" do
  let(:source) { File.read(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks/hecks.hecksagon")) }
  let(:filter) do
    block = source[/translates "FindWorkWhenTheJobsLandingIsRefused" do.*?where\s+(\{.*?\n?\s*\})\n\s+ask/m, 1]
    eval(<<~RUBY, binding, __FILE__, __LINE__ + 1)
      # proc { refusal.value.include?("conflict: ") || ... }
      proc #{block}
    RUBY
  end

  def reacts?(text)
    held = Struct.new(:refusal).new(Struct.new(:value).new(text))
    held.instance_exec(&filter)
  end

  it "plans the item again for a rebase conflict, a red gate and red impacted specs", :aggregate_failures do
    ["conflict: rebasing b onto main", "gate red: the quick gate failed", "impacted specs red: failing spec: a_spec.rb:90"]
      .each { |text| expect(reacts?(text)).to be(true), text }
  end

  it "leaves a red main and a held lock to a person", :aggregate_failures do
    ["main is red: flag 12", "locked: another landing holds the line"].each { |text| expect(reacts?(text)).to be(false), text }
  end
end

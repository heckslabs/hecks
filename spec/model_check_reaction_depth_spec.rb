require "spec_helper"
require "tempfile"

# model_check's finding for a reaction chain as deep as the dispatcher's limit. A command's events
# start policies, whose triggers and asks emit more events: a chain that reaches the limit has its
# last reactions refused, which nothing reports at run time.
RSpec.describe "model_check over reaction chain depth" do
  ERRAND_FOR_DEPTH = File.join(InMemoryDomain::ROOT, "spec/corpus/asks/domain/bluebook").freeze

  # A bluebook whose `Start` command begins a chain of `steps` policies, each triggering the next
  # step. With `loop_back`, the last policy triggers `Step1` again.
  def chain_of(steps, loop_back: false)
    file = Tempfile.new(["chain", ".bluebook"])
    file.write(chain_source(steps, loop_back))
    file.flush
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) { Kernel.load(file.path) }
    registry.bluebook("Chain")
  ensure
    file&.close!
  end

  def chain_source(steps, loop_back)
    <<~RUBY
      Hecks.bluebook "Chain" do
        aggregate "Link" do
          identified_by :ref
          attribute :ref, Ref
          value_object("Ref") { attribute :value, String }
          command("Start") do
            attribute :ref, Ref
            emits "Started"
          end
      #{(1..steps).map { |n| step_source(n) }.join}    end
      #{(1..steps).map { |n| policy_source(n) }.join}#{again_source(steps) if loop_back}  end
    RUBY
  end

  def step_source(number)
    "    command(\"Step#{number}\") do\n      reference_to Link\n      emits \"Stepped#{number}\"\n    end\n"
  end

  def policy_source(number)
    event = number == 1 ? "Started" : "Stepped#{number - 1}"
    "  policy \"P#{number}\" do\n    on \"#{event}\"\n    trigger Link::Step#{number}\n  end\n"
  end

  def again_source(steps)
    "  policy \"Again\" do\n    on \"Stepped#{steps}\"\n    trigger Link::Step1\n  end\n"
  end

  def findings_of(bluebook, **options) = Hecks::Bluebook::ModelCheck.reaction_depth_findings(bluebook, **options)

  def errand
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, *%w[errand.bluebook errand.hecksagon].map { |f| File.join(ERRAND_FOR_DEPTH, f) }]
        .each { |file| Kernel.load(file) }
    end
    registry.bluebook("Errand")
  end

  it "warns of a chain that reaches the limit, naming the entry command" do
    expect(findings_of(chain_of(5)).map { |f| [f.kind, f.severity, f.subject] })
      .to eq([[:deep_reaction_chain, :warning, "Chain::Link.Start"]])
  end

  it "names each policy and command of the chain in order" do
    expect(findings_of(chain_of(5)).first.message)
      .to include("Chain::Link.Start -> P1 -> Chain::Link.Step1 -> P2 -> Chain::Link.Step2 -> P3")
  end

  it "says which engine refuses which reaction" do
    expect(findings_of(chain_of(5)).first.message).to include("Rust refuses the 5th, Ruby the 6th")
  end

  it "is silent about a chain one short of the limit" do
    expect(findings_of(chain_of(4))).to be_empty
  end

  it "reports the entry command once, not every command along the chain" do
    expect(findings_of(chain_of(7)).map(&:subject)).to eq(["Chain::Link.Start"])
  end

  it "ends a chain where a loop closes, counting each policy once" do
    expect(findings_of(chain_of(5, loop_back: true)).first.message).to include("starts a chain of 6 reactions")
  end

  it "follows an ask through the hecksagon to the events its port operation answers" do
    expect(findings_of(errand, limit: 2).map(&:message).join).to include("Job.Worker.Run -> SettleWhenAnswered")
  end

  it "counts the chain of the same ask as 2 reactions" do
    expect(findings_of(errand, limit: 3)).to be_empty
  end

  it "runs with the model check itself" do
    expect(Hecks::Bluebook::ModelCheck.call(chain_of(5)).map(&:kind)).to include(:deep_reaction_chain)
  end
end

require "spec_helper"
require "tempfile"

# model_check's finding for a reaction chain longer than the dispatcher's limit. A command's events
# start policies, whose triggers and asks emit more events: a chain past the limit has its last
# reactions refused, which nothing reports at run time. A chain of exactly the limit runs whole.
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

  # A bluebook whose commands `Ping1`..`PingN` each emit `PingedK`, answered by a policy that
  # triggers the next ping, the last one triggering `Ping1` again: a loop of N policies that no
  # command outside it starts.
  def ring_of(size)
    commands = (1..size).map { |n| "command(\"Ping#{n}\") do\n reference_to Bell\n emits \"Pinged#{n}\"\n end\n" }
    policies = (1..size).map { |n| "policy \"P#{n}\" do\n on \"Pinged#{n}\"\n trigger Bell::Ping#{(n % size) + 1}\n end\n" }
    loaded_domain("Ring", "aggregate \"Bell\" do\n identified_by :ref\n attribute :ref, Ref\n" \
                          "value_object(\"Ref\") { attribute :value, String }\n#{commands.join}end\n#{policies.join}")
  end

  # Layers of two commands each emitting one event, every policy of a layer answering the
  # previous layer (the first answers `Start`): 2**layers paths from the first layer to the
  # last. With `loop_back` the last layer's event is also answered by the first layer's commands.
  def layered(layers, loop_back: false)
    commands = (0...layers).flat_map { |layer| %w[A B].map { |x| cell_command("#{x}#{layer}", "E#{layer}") } }
    policies = (0...layers).flat_map { |layer| %w[A B].map { |x| layer_policy(x, layer) } }
    policies += %w[A B].map { |x| cell_policy("Back#{x}", "E#{layers - 1}", "#{x}0") } if loop_back
    loaded_domain("Layers", cell_source(commands, policies))
  end

  def layer_policy(letter, layer)
    cell_policy("P#{letter}#{layer}", layer.zero? ? "Started" : "E#{layer - 1}", "#{letter}#{layer}")
  end

  def cell_source(commands, policies)
    "aggregate \"Cell\" do\n identified_by :ref\n attribute :ref, Ref\n" \
      "value_object(\"Ref\") { attribute :value, String }\n" \
      "command(\"Start\") do\n attribute :ref, Ref\n emits \"Started\"\n end\n#{commands.join}end\n#{policies.join}"
  end

  def cell_command(name, event) = "command(\"#{name}\") do\n reference_to Cell\n emits \"#{event}\"\n end\n"

  def cell_policy(name, event, command) = "policy \"#{name}\" do\n on \"#{event}\"\n trigger Cell::#{command}\n end\n"

  def loaded_domain(name, body)
    file = Tempfile.new([name.downcase, ".bluebook"])
    file.write("Hecks.bluebook \"#{name}\" do\n#{body}end\n")
    file.flush
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) { Kernel.load(file.path) }
    registry.bluebook(name)
  ensure
    file&.close!
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

  it "warns of a chain past the limit, naming the entry command" do
    expect(findings_of(chain_of(6)).map { |f| [f.kind, f.severity, f.subject] })
      .to eq([[:deep_reaction_chain, :warning, "Chain::Link.Start"]])
  end

  it "names each policy and command of the chain in order" do
    expect(findings_of(chain_of(6)).first.message)
      .to include("Chain::Link.Start -> P1 -> Chain::Link.Step1 -> P2 -> Chain::Link.Step2 -> P3")
  end

  it "says which reaction is the first one refused" do
    expect(findings_of(chain_of(6)).first.message).to include("the 6th and any after it are refused")
  end

  it "is silent about a chain of exactly the limit, which runs whole" do
    expect(findings_of(chain_of(5))).to be_empty
  end

  it "reports the entry command once, not every command along the chain" do
    expect(findings_of(chain_of(7)).map(&:subject)).to eq(["Chain::Link.Start"])
  end

  it "ends a chain where a loop closes, counting each policy once" do
    expect(findings_of(chain_of(5, loop_back: true)).first.message).to include("starts a chain of 6 reactions")
  end

  it "follows an ask through the hecksagon to the events its port operation answers" do
    expect(findings_of(errand, limit: 1).map(&:message).join).to include("Job.Worker.Run -> SettleWhenAnswered")
  end

  it "counts the chain of the same ask as 2 reactions" do
    expect(findings_of(errand, limit: 2)).to be_empty
  end

  it "flags a policy that answers its own command's event, which no command outside it starts" do
    expect(findings_of(ring_of(1)).map { |f| [f.kind, f.severity, f.subject] })
      .to eq([[:unbounded_reaction_loop, :warning, "P1"]])
  end

  it "flags a loop through two policies, naming both" do
    expect(findings_of(ring_of(2)).map { |f| [f.kind, f.subject] }).to eq([[:unbounded_reaction_loop, "P1, P2"]])
  end

  it "says the loop is cut by the limit" do
    expect(findings_of(ring_of(2)).first.message).to include("until the reaction depth limit of 5")
  end

  it "flags a loop that closes a chain from an entry command beside the chain's own depth" do
    kinds = findings_of(chain_of(5, loop_back: true)).map(&:kind)

    expect(kinds).to contain_exactly(:deep_reaction_chain, :unbounded_reaction_loop)
  end

  it "reports a long chain with no loop for its depth only" do
    expect(findings_of(chain_of(8)).map(&:kind)).to eq([:deep_reaction_chain])
  end

  it "finds the deepest chain through many paths without walking each of them" do
    found = findings_of(layered(40)).map { |f| [f.kind, f.message[/chain of \d+/]] }

    expect(found).to eq([[:deep_reaction_chain, "chain of 40"]])
  end

  it "stops searching a looping graph with many paths, and says the chain is a lower bound" do
    expect(findings_of(layered(16, loop_back: true)).map(&:kind)).to include(:reaction_chain_search_capped)
  end

  it "runs with the model check itself" do
    expect(Hecks::Bluebook::ModelCheck.call(chain_of(6)).map(&:kind)).to include(:deep_reaction_chain)
  end
end

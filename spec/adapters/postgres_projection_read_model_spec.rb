require "spec_helper"
require "tempfile"
require "hecks/fuzzing"
require_relative "../support/postgres_probe"

# PostgresProjection answers a rooted read model from its own tables the way the in-process path
# does (ADR 0122): a chained include (a head referencing another included head, not the root)
# still resolves, scoped to one root, and a missing root refuses with `NotFound`.
RSpec.describe "Adapters::PostgresProjection#query_read_model", :io do
  POSTGRES_CHAIN_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "PostgresChainProjection" do
      aggregate "Root" do
        identified_by :ref
        attribute :ref, Ref
        attribute :rank, Integer
        value_object "Ref" do
          attribute :value, String
        end
        command "Make" do
          attribute :ref, Ref
          attribute :rank, Integer
          sets :ref
          sets :rank
          emits "RootMade"
        end
      end

      aggregate "Mid" do
        identified_by :ref
        attribute :ref, Ref
        reference_to Root, as: :root
        value_object "Ref" do
          attribute :value, String
        end
        command "Make" do
          attribute :ref, Ref
          reference_to Root
          sets :ref
          sets :root
          emits "MidMade"
        end
      end

      aggregate "Leaf" do
        identified_by :ref
        attribute :ref, Ref
        reference_to Mid, as: :mid
        value_object "Ref" do
          attribute :value, String
        end
        command "Make" do
          attribute :ref, Ref
          reference_to Mid
          sets :ref
          sets :mid
          emits "LeafMade"
        end
      end

      read_model "Chain" do
        reference_to Root
        include Root
        include Mid
        include Leaf
      end
    end
  BLUEBOOK

  CHAIN_AGGREGATES = %w[Root Mid Leaf].freeze

  def boot
    schema = "postgres_projection_spec"
    Hecks::Fuzzing::IsolatedBoot.ensure_fuzz_schema!(Hecks::Fuzzing::IsolatedBoot::FUZZ_POSTGRES_DATABASE, schema)
    registry = Hecks::Runtime::Registry.new
    Hecks::Bluebook::MetaValidator.while_disabled { Hecks.with_registry(registry) { declare_chain(schema) } }
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def declare_chain(schema)
    load_chain_ports
    Kernel.eval(POSTGRES_CHAIN_SOURCE, TOPLEVEL_BINDING, "postgres_chain_projection.bluebook", 1)
    declare_chain_bindings(schema)
  end

  def declare_chain_bindings(schema)
    Hecks.hecksagon("PostgresChainProjection") do
      persisted_by "Memory"
      projected_by "PostgresProjection"
    end
    Hecks.world("PostgresChainProjection") do
      projected_by("PostgresProjection") do
        database Hecks::Fuzzing::IsolatedBoot::FUZZ_POSTGRES_DATABASE
        schema schema
      end
    end
  end

  def load_chain_ports
    Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
    Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/ports/projection.port"))
    Kernel.load(InMemoryDomain::EXTRACTION_PORT)
    Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
    Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/postgres.adapter"))
    Kernel.load(InMemoryDomain::PRISM_ADAPTER)
  end

  # The command-side write path never advances a projection; only a worker does.
  def catch_up_projections(registry)
    CHAIN_AGGREGATES.each do |name|
      aggregate = registry.bluebook("PostgresChainProjection").aggregate(name)
      Hecks::Ports::Projection.worker(registry, "PostgresChainProjection", aggregate, policy: :strict).catch_up!
    end
  end

  def root_read_adapter(runtime)
    root = runtime.registry.bluebook("PostgresChainProjection").aggregate("Root")
    runtime.registry.read_repository("PostgresChainProjection", root).adapter
  end

  # Two chains, so the join can be shown scoped to one root's descendants.
  def make_two_chains
    PostgresChainProjection::Root.make!(ref: { value: "r1" }, rank: 7)
    PostgresChainProjection::Mid.make!(ref: { value: "m1" }, root: "r1")
    PostgresChainProjection::Leaf.make!(ref: { value: "l1" }, mid: "m1")
    PostgresChainProjection::Root.make!(ref: { value: "r2" }, rank: 9)
    PostgresChainProjection::Mid.make!(ref: { value: "m2" }, root: "r2")
    PostgresChainProjection::Leaf.make!(ref: { value: "l2" }, mid: "m2")
  end

  def chain_for(root)
    make_two_chains
    catch_up_projections(runtime.registry)
    runtime.query("PostgresChainProjection.chain", root: root).first
  end

  let(:runtime) { boot }

  # Booted before any example dispatches, so the bluebook's constants are this runtime's.
  before do
    skip "no reachable Postgres" unless PostgresProbe.available?
    runtime
  end

  it "answers from the projection once it is caught up" do
    chain_for("r1")
    expect(root_read_adapter(runtime)).to be_a(Hecks::Adapters::PostgresProjection)
  end

  it "joins a chained (non-root) include the same way the in-process path does", :aggregate_failures do
    answer = chain_for("r1")
    expect(answer[:mids].map { |mid| mid[:id] }).to eq(["m1"])
    expect(answer[:leafs].map { |leaf| leaf[:id] }).to eq(["l1"])
  end

  it "reads a declared number back as a number, not the text Postgres answers" do
    expect(chain_for("r2")[:root][:rank]).to eq(9)
  end

  it "refuses a missing root reference with NotFound, the same as the in-process path" do
    catch_up_projections(runtime.registry)
    expect { runtime.query("PostgresChainProjection.chain", root: "no-such-root") }
      .to raise_error(Hecks::Runtime::NotFound, /no Root with reference "no-such-root"/)
  end
end

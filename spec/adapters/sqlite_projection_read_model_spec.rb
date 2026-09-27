require "spec_helper"
require "tmpdir"
require "tempfile"

# The native SQLite projection path must agree with the in-process read-model path on:
# - a missing root reference: `NotFound`, not a silent `{root: nil, ...}`;
# - a chained include (a head referencing another included head, not the root): its rows
#   must still resolve.
RSpec.describe "Adapters::SqliteProjection#query_read_model" do
  SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "ChainProjectionGrowth" do
      aggregate "Root" do
        identified_by :ref
        attribute :ref, Ref
        value_object "Ref" do
          attribute :value, String
        end
        command "Make" do
          attribute :ref, Ref
          sets :ref
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

      # REFERENCES Mid, NOT Root — the exact shape that used to defeat
      # the native path's own join: `Leaf` declares no attribute
      # referencing `Root` at all, only `Mid`.
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

  def boot(dir)
    file = Tempfile.new(["chain-projection-growth-", ".bluebook"])
    file.write(SOURCE)
    file.flush

    registry = Hecks::Runtime::Registry.new(root: dir)
    Hecks::Bluebook::MetaValidator.while_disabled do
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/ports/projection.port"))
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter"))
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.eval(SOURCE, TOPLEVEL_BINDING, file.path, 1)
        Hecks.hecksagon("ChainProjectionGrowth") do
          ChainProjectionGrowth::Root.persisted_by("SqlitePersistence")
          ChainProjectionGrowth::Root.projected_by("SqliteProjection")
          ChainProjectionGrowth::Mid.persisted_by("SqlitePersistence")
          ChainProjectionGrowth::Mid.projected_by("SqliteProjection")
          ChainProjectionGrowth::Leaf.persisted_by("SqlitePersistence")
          ChainProjectionGrowth::Leaf.projected_by("SqliteProjection")
        end
        Hecks.world("ChainProjectionGrowth") do
          persisted_by("SqlitePersistence") { database(File.join(dir, "chain-authoritative.db")) }
          projected_by("SqliteProjection") { database(File.join(dir, "chain-projection.db")) }
        end
      end
    end

    registry.verify!
    runtime = Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))

    # The command-side write path never advances a projection; only a worker does.
    %w[Root Mid Leaf].each do |name|
      aggregate = registry.bluebook("ChainProjectionGrowth").aggregate(name)
      Hecks::Ports::Projection.worker(registry, "ChainProjectionGrowth", aggregate)&.catch_up!
    end

    runtime
  ensure
    file&.close!
  end

  # Guards against a false pass: without a `projected_by` binding the read model silently
  # falls back to the in-process loop.
  def assert_native_path!(runtime)
    root = runtime.registry.bluebook("ChainProjectionGrowth").aggregate("Root")
    repository = runtime.registry.read_repository("ChainProjectionGrowth", root)
    unless repository.adapter.is_a?(Hecks::Adapters::SqliteProjection)
      raise "expected the native SqliteProjection path, got #{repository.adapter.class}"
    end
  end

  it "joins a chained (non-root) include the same way the in-process path does" do
    Dir.mktmpdir do |dir|
      runtime = boot(dir)
      assert_native_path!(runtime)

      ChainProjectionGrowth::Root.make!(ref: { value: "r1" })
      ChainProjectionGrowth::Mid.make!(ref: { value: "m1" }, root: "r1")
      ChainProjectionGrowth::Leaf.make!(ref: { value: "l1" }, mid: "m1")

      # A second, unrelated chain proves the join is scoped to this root's descendants.
      ChainProjectionGrowth::Root.make!(ref: { value: "r2" })
      ChainProjectionGrowth::Mid.make!(ref: { value: "m2" }, root: "r2")
      ChainProjectionGrowth::Leaf.make!(ref: { value: "l2" }, mid: "m2")

      %w[Root Mid Leaf].each do |name|
        aggregate = runtime.registry.bluebook("ChainProjectionGrowth").aggregate(name)
        Hecks::Ports::Projection.worker(runtime.registry, "ChainProjectionGrowth", aggregate)&.catch_up!
      end

      rows = runtime.query("ChainProjectionGrowth.chain", root: "r1")

      expect(rows.first[:mids].map { |m| m[:id] }).to eq(["m1"])
      expect(rows.first[:leafs].map { |l| l[:id] }).to eq(["l1"])
    end
  end

  it "refuses a missing root reference with NotFound, the same as the in-process path" do
    Dir.mktmpdir do |dir|
      runtime = boot(dir)
      assert_native_path!(runtime)

      expect { runtime.query("ChainProjectionGrowth.chain", root: "no-such-root") }
        .to raise_error(Hecks::Runtime::NotFound, /no Root with reference "no-such-root"/)
    end
  end
end

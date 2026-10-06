require "spec_helper"
require "hecks/ports/persistence/plugins/era"
require "tmpdir"

# Frozen era text must stay readable under the grammar live when it was written (ADR 0025).
# The vision rule lives only in the meta-domain, so `while_shadow_parsing` must hold it off.
RSpec.describe "shadow-parsing frozen era text against a legacy grammar" do
  EMPTY_VISION = <<~BLUEBOOK.freeze
    Hecks.bluebook "ShadowParseFixture" do
      vision ""
      generic

      aggregate "Thing" do
        identified_by :name

        attribute :name, ThingName

        value_object "ThingName" do
          attribute :value, String
        end
      end
    end
  BLUEBOOK

  # The `identified_by` block's source is read back off disk, so the fixture must be a real
  # file at the path it is eval'd under.
  def fixture_path(dir, name) = File.join(dir, "#{name}.bluebook")

  # Writes `source` to a real file named `name` in a throwaway directory and yields its path.
  def with_fixture(name, source)
    Dir.mktmpdir do |dir|
      path = fixture_path(dir, name)
      File.write(path, source)
      yield path
    end
  end

  # Shadow-parses `source` from a real file and yields the bluebook it reads.
  def shadow_parsed(name, source)
    with_fixture(name, source) { |path| yield Hecks::Runtime::EraGuard.shadow_parse(source, path) }
  end

  def eval_live(source, path)
    registry = Hecks::Runtime::Registry.new
    loading  = Hecks::Ports::Loading.bootstrap
    Hecks.with_registry(registry) do
      loading.load_library
      Kernel.eval(source, TOPLEVEL_BINDING, path, 1)
    end
    registry
  end

  it "still refuses an empty vision in LIVE source, unchanged" do
    with_fixture("live", EMPTY_VISION) do |path|
      expect { eval_live(EMPTY_VISION, path) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /a vision says something/)
    end
  end

  it "parses the identical text through shadow_parse, where a live boot would refuse it", :aggregate_failures do
    shadow_parsed("shadow", EMPTY_VISION) do |bluebook|
      expect(bluebook.hecks_name).to eq("ShadowParseFixture")
      expect(bluebook.aggregate("Thing").attribute(:name)).not_to be_nil
    end
  end

  it "never leaks the flag past shadow_parse's own call — the next live boot refuses again" do
    shadow_parsed("shadow2", EMPTY_VISION) { |bluebook| bluebook }

    with_fixture("live2", EMPTY_VISION) do |path|
      expect { eval_live(EMPTY_VISION, path) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /a vision says something/)
    end
  end

  # Dotted-hop (`/`) where clauses through shadow_parse. The `.` spelling was never one of the
  # removed spellings shadow-parsing keeps readable, so it must refuse loudly rather than be
  # read as a local dotted field; the `/` spelling parses with no legacy fallback.
  describe "a dotted-hop (`/`) where clause" do
    HOP_CHAIN_SOURCE = File.read(File.join(__dir__, "fixtures/hop_chain.bluebook")).freeze

    it "parses cleanly through shadow_parse, on the normal-parse branch, with no legacy fallback needed", :aggregate_failures do
      shadow_parsed("hop_chain", HOP_CHAIN_SOURCE) do |bluebook|
        query = bluebook.aggregate("Proposal").query("AwaitingReplyFromActiveClients")

        expect(bluebook.hecks_name).to eq("HopChain")
        expect(query.wheres.map(&:field)).to include("engagement/client/status")
      end
    end

    # Minimal fixture (not hop_chain.bluebook): `while_shadow_parsing` also reverts
    # `reference_to`'s default naming, which would give a busier fixture a second reason to refuse.
    DOTTED_HOP_SOURCE = <<~BLUEBOOK.freeze
      Hecks.bluebook "DottedHopFixture" do
        generic

        aggregate "Client" do
          identified_by :name
          attribute :name, Name
          value_object("Name") { attribute :value, String }

          lifecycle :status, default: "active" do
            transition "Churn" => "churned", from: "active"
          end

          command "Register" do
            attribute :name, Name
            sets :name
            emits "Registered"
          end
        end

        aggregate "Engagement" do
          identified_by :reference
          reference_to Client
          attribute :reference, Reference
          value_object("Reference") { attribute :value, String }

          command "Start" do
            reference_to Client
            attribute :reference, Reference
            sets :reference
            emits "Started"
          end

          query "WithActiveClient" do
            where :"client.status" => "active"
          end
        end
      end
    BLUEBOOK

    it "still refuses the pre-ADR-0025 dot spelling of the same hop under live parse" do
      with_fixture("dotted_hop_live", DOTTED_HOP_SOURCE) do |path|
        expect { eval_live(DOTTED_HOP_SOURCE, path) }
          .to raise_error(Hecks::Bluebook::DSL::Malformed, /client\.status.*never declares/m)
      end
    end

    it "still refuses the pre-ADR-0025 dot spelling of the same hop under shadow parse" do
      with_fixture("dotted_hop_shadow", DOTTED_HOP_SOURCE) do |path|
        expect { Hecks::Runtime::EraGuard.shadow_parse(DOTTED_HOP_SOURCE, path) }
          .to raise_error(Hecks::Bluebook::DSL::Malformed, /client\.status.*never declares/m)
      end
    end
  end

  describe "MetaValidator.while_shadow_parsing" do
    def seen_inside_block
      seen = nil
      Hecks::Bluebook::MetaValidator.while_shadow_parsing { seen = Hecks::Bluebook::MetaValidator.shadow_parsing? }
      seen
    end

    it "is off by default, and restores itself even when the block raises", :aggregate_failures do
      expect(Hecks::Bluebook::MetaValidator).not_to be_shadow_parsing

      expect { Hecks::Bluebook::MetaValidator.while_shadow_parsing { raise "boom" } }
        .to raise_error("boom")

      expect(Hecks::Bluebook::MetaValidator).not_to be_shadow_parsing
    end

    it "is on for exactly the span of its own block", :aggregate_failures do
      expect(seen_inside_block).to be(true)
      expect(Hecks::Bluebook::MetaValidator).not_to be_shadow_parsing
    end
  end
end

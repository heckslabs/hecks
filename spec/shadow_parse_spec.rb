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
    Dir.mktmpdir do |dir|
      path = fixture_path(dir, "live")
      File.write(path, EMPTY_VISION)

      expect { eval_live(EMPTY_VISION, path) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /a vision says something/)
    end
  end

  it "parses the identical text through shadow_parse, where a live boot would refuse it" do
    Dir.mktmpdir do |dir|
      path = fixture_path(dir, "shadow")
      File.write(path, EMPTY_VISION)

      bluebook = Hecks::Runtime::EraGuard.shadow_parse(EMPTY_VISION, path)

      expect(bluebook.hecks_name).to eq("ShadowParseFixture")
      expect(bluebook.aggregate("Thing").attribute(:name)).not_to be_nil
    end
  end

  it "never leaks the flag past shadow_parse's own call — the next live boot refuses again" do
    Dir.mktmpdir do |dir|
      shadow_path = fixture_path(dir, "shadow2")
      live_path   = fixture_path(dir, "live2")
      File.write(shadow_path, EMPTY_VISION)
      File.write(live_path, EMPTY_VISION)

      Hecks::Runtime::EraGuard.shadow_parse(EMPTY_VISION, shadow_path)

      expect { eval_live(EMPTY_VISION, live_path) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /a vision says something/)
    end
  end

  # Dotted-hop (`/`) where clauses through shadow_parse. The `.` spelling was never one of the
  # removed spellings shadow-parsing keeps readable, so it must refuse loudly rather than be
  # read as a local dotted field; the `/` spelling parses with no legacy fallback.
  describe "a dotted-hop (`/`) where clause" do
    HOP_CHAIN_SOURCE = File.read(File.join(__dir__, "fixtures/hop_chain.bluebook")).freeze

    it "parses cleanly through shadow_parse, on the normal-parse branch, with no legacy fallback needed" do
      Dir.mktmpdir do |dir|
        path = fixture_path(dir, "hop_chain")
        File.write(path, HOP_CHAIN_SOURCE)

        bluebook = Hecks::Runtime::EraGuard.shadow_parse(HOP_CHAIN_SOURCE, path)

        expect(bluebook.hecks_name).to eq("HopChain")
        query = bluebook.aggregate("Proposal").query("AwaitingReplyFromActiveClients")
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

    it "still refuses the pre-ADR-0025 dot spelling of the same hop, under both live and shadow parse" do
      Dir.mktmpdir do |dir|
        live_path = fixture_path(dir, "dotted_hop_live")
        File.write(live_path, DOTTED_HOP_SOURCE)

        expect { eval_live(DOTTED_HOP_SOURCE, live_path) }
          .to raise_error(Hecks::Bluebook::DSL::Malformed, /client\.status.*never declares/m)

        shadow_path = fixture_path(dir, "dotted_hop_shadow")
        File.write(shadow_path, DOTTED_HOP_SOURCE)

        expect { Hecks::Runtime::EraGuard.shadow_parse(DOTTED_HOP_SOURCE, shadow_path) }
          .to raise_error(Hecks::Bluebook::DSL::Malformed, /client\.status.*never declares/m)
      end
    end
  end

  describe "MetaValidator.while_shadow_parsing" do
    it "is off by default, and restores itself even when the block raises" do
      expect(Hecks::Bluebook::MetaValidator).not_to be_shadow_parsing

      expect { Hecks::Bluebook::MetaValidator.while_shadow_parsing { raise "boom" } }
        .to raise_error("boom")

      expect(Hecks::Bluebook::MetaValidator).not_to be_shadow_parsing
    end

    it "is on for exactly the span of its own block" do
      seen_inside = nil
      Hecks::Bluebook::MetaValidator.while_shadow_parsing do
        seen_inside = Hecks::Bluebook::MetaValidator.shadow_parsing?
      end

      expect(seen_inside).to be(true)
      expect(Hecks::Bluebook::MetaValidator).not_to be_shadow_parsing
    end
  end
end

require "spec_helper"
require "hecks/ports/persistence/plugins/era"
require "tmpdir"

# ADR 0025's own prerequisite (docs/dsl-work-slices.md, slice S0a): no
# spelling can be removed from the LIVE grammar until frozen era text
# can still be read under whatever grammar was live when it was
# written. `EraGuard.shadow_parse` runs a plain `Kernel.eval` of stored
# source at boot, at mint, and during tamper detection — against
# TODAY's grammar unless something tells it otherwise, which would
# refuse HISTORY the day a spelling it used is removed.
#
# Proved against a rule that ALREADY exists ONLY in the meta-domain,
# never duplicated as a builder's own `raise Malformed` —
# `BluebookBuilder#vision`'s own comment says so: "moved to the
# language: Vision invariant, on Chapter.Declare". That makes it the
# one real, present-day case where `MetaValidator`'s judging is the
# ONLY thing that would refuse this text, which is exactly what
# `while_shadow_parsing` has to hold off — not a spelling invented for
# this spec, and not a future removal pre-empted from this slice.
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

  # `identified_by { ... }`'s block is never CALLED — its source is read
  # back off DISK the same way a `given`'s is (`Ports::Extraction`,
  # `AggregateBuilder#identified_by`'s own comment), so the fixture has
  # to be a REAL file at the path it is eval'd under, not a string
  # handed a made-up name.
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

  # A DOTTED-HOP (`/`) WHERE CLAUSE THROUGH THE ERA/SHADOW-PARSE PATH —
  # found live while moving QualityControl's own ledger onto PostgresEra
  # (qa/bluebook/quality_control.bluebook's `Ticket.RestingOnUnpaused`,
  # `where(:"bug/status" => ...)`). The failure that surfaced there was
  # NOT a bug in this machinery: a stale LOCAL Postgres database, left
  # over from earlier manual testing of this same binding, held era text
  # written under the PRE-ADR-0025 spelling (`where(:"bug.status" =>
  # ...)`, a dot) — a spelling `seal_query_field` correctly refuses under
  # BOTH the live grammar and the shadow-parse fallback, because a dotted
  # hop was never one of the "genuinely removed spellings" shadow-parsing
  # exists to keep readable (see this file's own header, and era_guard.rb's
  # `shadow_parse` comment) — only `identified_by { }`/`belongs_to`/
  # `has_one`/`has_many`, and `reference_to`'s default-naming fork, are.
  # These two examples pin both halves: the CURRENT `/` spelling parses
  # clean through `shadow_parse` needing no legacy fallback at all, and
  # the OLD `.` spelling refuses loudly rather than silently
  # misinterpreting the hop as a local dotted field — the same honest
  # refusal a live boot already gives, not a special case shadow-parsing
  # quietly forgives.
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

    # A MINIMAL, SELF-CONTAINED fixture (not hop_chain.bluebook) —
    # deliberately ONE aggregate, ONE reference, ONE query, so the only
    # thing this proves is dot-vs-slash. `MetaValidator.while_shadow_
    # parsing` also reverts `reference_to`'s default-naming convention
    # (era_guard.rb's own `shadow_parse` comment), which would give a
    # SECOND, unrelated reason for a busier fixture's own default-named
    # hop queries to refuse under the shadow branch — a real interaction,
    # but a different question than the one this example asks.
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

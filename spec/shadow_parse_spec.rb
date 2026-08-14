require "spec_helper"
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
        identified_by { name.value }

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
    registry = Hecksagain::Runtime::Registry.new
    loading  = Hecksagain::Ports::Loading.bootstrap
    Hecksagain.with_registry(registry) do
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
        .to raise_error(Hecksagain::Bluebook::DSL::Malformed, /a vision says something/)
    end
  end

  it "parses the identical text through shadow_parse, where a live boot would refuse it" do
    Dir.mktmpdir do |dir|
      path = fixture_path(dir, "shadow")
      File.write(path, EMPTY_VISION)

      bluebook = Hecksagain::Runtime::EraGuard.shadow_parse(EMPTY_VISION, path)

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

      Hecksagain::Runtime::EraGuard.shadow_parse(EMPTY_VISION, shadow_path)

      expect { eval_live(EMPTY_VISION, live_path) }
        .to raise_error(Hecksagain::Bluebook::DSL::Malformed, /a vision says something/)
    end
  end

  describe "MetaValidator.while_shadow_parsing" do
    it "is off by default, and restores itself even when the block raises" do
      expect(Hecksagain::Bluebook::MetaValidator.shadow_parsing?).to be_falsy

      expect { Hecksagain::Bluebook::MetaValidator.while_shadow_parsing { raise "boom" } }
        .to raise_error("boom")

      expect(Hecksagain::Bluebook::MetaValidator.shadow_parsing?).to be_falsy
    end

    it "is on for exactly the span of its own block" do
      seen_inside = nil
      Hecksagain::Bluebook::MetaValidator.while_shadow_parsing do
        seen_inside = Hecksagain::Bluebook::MetaValidator.shadow_parsing?
      end

      expect(seen_inside).to be(true)
      expect(Hecksagain::Bluebook::MetaValidator.shadow_parsing?).to be_falsy
    end
  end
end

require "spec_helper"
require "tmpdir"

# End-to-end proof that environment overlays and vendored bluebooks work
# against a real boot, not just the builder in isolation — dsl_spec.rb
# covers the builder-level surface.
RSpec.describe "environment overlays and vendored bluebooks" do
  def write(dir, relative, content)
    path = File.join(dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  # A minimal real domain, one command, one role — just enough to prove
  # the ungoverned-role check runs against the merged hecksagon (see
  # Registry::Verification#refuse_ungoverned_roles!).
  def bluebook_source(role:)
    <<~BLUEBOOK
      Hecks.bluebook "Overlaid" do
        vision "one thing, one command, to exercise a hecksagon split across files"
        core

        aggregate "Thing" do
          description "a thing"
          identified_by :ref

          value_object "Ref" do
            attribute :value, String
            invariant("a thing has a ref") { !value.to_s.empty? }
          end

          attribute :ref, Ref

          command "Make" do
            role "#{role}"
            goal "make a thing"
            attribute :ref, Ref
            emits "ThingMade"
          end
        end
      end
    BLUEBOOK
  end

  GOVERNED_HECKSAGON = <<~HECKSAGON.freeze
    Hecks.hecksagon "Overlaid" do
      attaches "Governance"
      Overlaid::Thing.persisted_by("Memory")
    end
  HECKSAGON

  UNGOVERNED_HECKSAGON = <<~HECKSAGON.freeze
    Hecks.hecksagon "Overlaid" do
      Overlaid::Thing.persisted_by("Memory")
    end
  HECKSAGON

  SUBSCRIBE_OVERLAY = <<~HECKSAGON.freeze
    Hecks.hecksagon "Overlaid" do
      subscribe "SomeOutsideEvent"
    end
  HECKSAGON

  ATTACH_OVERLAY = <<~HECKSAGON.freeze
    Hecks.hecksagon "Overlaid" do
      attaches "Governance"
    end
  HECKSAGON

  BASE_WORLD = <<~WORLD.freeze
    Hecks.world "Overlaid" do
      realm "Overlaid"
    end
  WORLD

  PRODUCTION_WORLD = <<~WORLD.freeze
    Hecks.world "Overlaid" do
      realm "Overlaid"
      posted_by("Carrier") do
        office "EC1"
      end
    end
  WORLD

  OVERLAY_WIDGETS_BLUEBOOK = <<~BLUEBOOK.freeze
    Hecks.bluebook "Widgets" do
      vision "a vendored package with a value object"
      core

      aggregate "Widget" do
        description "a widget"
        identified_by :ref

        value_object "Ref" do
          attribute :value, String
          invariant("a widget has a ref") { !value.to_s.empty? }
        end

        attribute :ref, Ref

        command "Make" do
          role "Someone"
          goal "make a widget"
          attribute :ref, Ref
          emits "WidgetMade"
        end
      end
    end
  BLUEBOOK

  CONSUMER_HECKSAGON = <<~HECKSAGON.freeze
    Hecks.hecksagon "Widgets" do
      attaches "widgets", from: :vendor
      attaches "Governance"
      Widgets::Widget.persisted_by("Memory")
    end
  HECKSAGON

  let(:dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(dir) }

  # The Overlaid bluebook and its base hecksagon, with the Governance context map unless left out.
  def write_overlaid(hecksagon, context_map: true)
    write(dir, "overlaid.bluebook", bluebook_source(role: "Someone"))
    write(dir, "overlaid.hecksagon", hecksagon)
    write(dir, "context_map.hecksagon", InMemoryDomain::GOVERNANCE_MEMORY_HECKSAGON) if context_map
  end

  # The base world and the production overlay that adds a poster to it.
  def write_worlds
    write(dir, "overlaid.world", BASE_WORLD)
    write(dir, "environments/production.world", PRODUCTION_WORLD)
  end

  # A vendored package's own bluebook plus a consumer hecksagon beside it.
  def write_vendored_widgets
    write(dir, "vendor/embryonaut_bluebooks/widgets/bluebook/widget.bluebook", OVERLAY_WIDGETS_BLUEBOOK)
    write(dir, "bluebook/consumer.hecksagon", CONSUMER_HECKSAGON)
    write(dir, "bluebook/context_map.hecksagon", InMemoryDomain::GOVERNANCE_MEMORY_HECKSAGON)
  end

  describe "environment: overlay (Hecksagon)" do
    it "merges an environments/<name>.hecksagon overlay's binds into the base rather than replacing them", :aggregate_failures do
      write_overlaid(GOVERNED_HECKSAGON)
      write(dir, "environments/production.hecksagon", SUBSCRIBE_OVERLAY)

      hexagon = Hecks.boot(dir, environment: "production", install_doors: false).registry.hecksagon("Overlaid")

      expect(hexagon.subscriptions).to eq(["SomeOutsideEvent"])
      expect(hexagon.bind_for("Thing", "persisted_by").adapter).to eq("Memory")
    end

    # Base declares no Governance — an overlay-only `attaches "Governance"` must still be enough.
    # Checking each block in isolation would wrongly refuse the base block, even though the
    # final, merged hecksagon is fine.
    it "checks the ungoverned-role refusal against the MERGED hecksagon, not each block alone" do
      write_overlaid(UNGOVERNED_HECKSAGON)
      write(dir, "environments/production.hecksagon", ATTACH_OVERLAY)

      expect { Hecks.boot(dir, environment: "production") }.not_to raise_error
    end

    it "still refuses an ungoverned role when NEITHER block attaches Governance" do
      write_overlaid(UNGOVERNED_HECKSAGON, context_map: false)

      expect { Hecks.boot(dir) }
        .to raise_error(Hecks::Runtime::WiringError, /never attaches "Governance"/)
    end
  end

  describe "environment: overlay (World)" do
    # World overlay + sibling ACL in one boot; splitting would re-pay the
    # tmpdir write without proving more than this one merge already does.
    it "merges an environments/<name>.world overlay's settings into the base rather than replacing them", :aggregate_failures do
      write_overlaid(GOVERNED_HECKSAGON)
      write_worlds

      world = Hecks.boot(dir, environment: "production", install_doors: false).registry.world("Overlaid")

      expect(world.realm).to eq("Overlaid")
      expect(world.for_verb("posted_by")).to include(adapter: "Carrier", office: "EC1")
    end
  end

  describe "attaches ... from: :vendor" do
    # One real boot over a vendored package's own bluebook plus a consumer
    # hecksagon; the three expects each inspect a different facet of that
    # same successful boot (registry contents, recorded vendor list, vendor
    # dir on disk) — splitting would re-pay the two-file-write-and-boot
    # setup three times to prove nothing more than this one boot already
    # does.
    it "loads every .bluebook file a vendored package declares, sorted, from the registry's own root", :aggregate_failures do
      write_vendored_widgets

      dispatcher = Hecks.boot(File.join(dir, "bluebook"), install_doors: false)

      expect(dispatcher.registry.bluebook("Widgets")).not_to be_nil
      expect(dispatcher.registry.hecksagon("Widgets").vendored_packages).to eq(["widgets"])
      expect(File.directory?(File.join(dir, "vendor", "embryonaut_bluebooks", "widgets", "bluebook"))).to be true
    end

    it "refuses with a real registry that has no root to vendor from" do
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        expect { Hecks::EmbryonautBluebook.load!("payments") }
          .to raise_error(Hecks::Runtime::WiringError, /needs a registry with a root to vendor from/)
      end
    end
  end
end

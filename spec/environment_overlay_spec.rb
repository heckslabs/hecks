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

  describe "environment: overlay (Hecksagon)" do
    it "merges an environments/<name>.hecksagon overlay's binds into the base rather than replacing them" do
      Dir.mktmpdir do |dir|
        write(dir, "overlaid.bluebook", bluebook_source(role: "Someone"))
        write(dir, "overlaid.hecksagon", <<~HECKSAGON)
          Hecks.hecksagon "Overlaid" do
            attaches "Governance"
            Overlaid::Thing.persisted_by("Memory")
          end
        HECKSAGON
        write(dir, "context_map.hecksagon", InMemoryDomain::GOVERNANCE_MEMORY_HECKSAGON)
        write(dir, "environments/production.hecksagon", <<~HECKSAGON)
          Hecks.hecksagon "Overlaid" do
            subscribe "SomeOutsideEvent"
          end
        HECKSAGON

        dispatcher = Hecks.boot(dir, environment: "production", install_doors: false)
        hexagon = dispatcher.registry.hecksagon("Overlaid")

        expect(hexagon.subscriptions).to eq(["SomeOutsideEvent"])
        expect(hexagon.bind_for("Thing", "persisted_by").adapter).to eq("Memory")
      end
    end

    it "checks the ungoverned-role refusal against the MERGED hecksagon, not each block alone" do
      Dir.mktmpdir do |dir|
        write(dir, "overlaid.bluebook", bluebook_source(role: "Someone"))
        # Base declares no Governance — an overlay-only `attaches
        # "Governance"` must still be enough. Checking each block in
        # isolation would wrongly refuse the base block, even though the
        # final, merged hecksagon is fine.
        write(dir, "overlaid.hecksagon", <<~HECKSAGON)
          Hecks.hecksagon "Overlaid" do
            Overlaid::Thing.persisted_by("Memory")
          end
        HECKSAGON
        write(dir, "environments/production.hecksagon", <<~HECKSAGON)
          Hecks.hecksagon "Overlaid" do
            attaches "Governance"
          end
        HECKSAGON
        write(dir, "context_map.hecksagon", InMemoryDomain::GOVERNANCE_MEMORY_HECKSAGON)

        expect { Hecks.boot(dir, environment: "production") }.not_to raise_error
      end
    end

    it "still refuses an ungoverned role when NEITHER block attaches Governance" do
      Dir.mktmpdir do |dir|
        write(dir, "overlaid.bluebook", bluebook_source(role: "Someone"))
        write(dir, "overlaid.hecksagon", <<~HECKSAGON)
          Hecks.hecksagon "Overlaid" do
            Overlaid::Thing.persisted_by("Memory")
          end
        HECKSAGON

        expect { Hecks.boot(dir) }
          .to raise_error(Hecks::Runtime::WiringError, /never attaches "Governance"/)
      end
    end
  end

  describe "environment: overlay (World)" do
    # World overlay + sibling ACL in one boot; splitting would re-pay the
    # tmpdir write without proving more than this one merge already does.
    # rubocop:disable-next RSpec/ExampleLength
    it "merges an environments/<name>.world overlay's settings into the base rather than replacing them" do
      Dir.mktmpdir do |dir|
        write(dir, "overlaid.bluebook", bluebook_source(role: "Someone"))
        write(dir, "overlaid.hecksagon", <<~HECKSAGON)
          Hecks.hecksagon "Overlaid" do
            attaches "Governance"
            Overlaid::Thing.persisted_by("Memory")
          end
        HECKSAGON
        write(dir, "context_map.hecksagon", InMemoryDomain::GOVERNANCE_MEMORY_HECKSAGON)
        write(dir, "overlaid.world", <<~WORLD)
          Hecks.world "Overlaid" do
            realm "Overlaid"
          end
        WORLD
        write(dir, "environments/production.world", <<~WORLD)
          Hecks.world "Overlaid" do
            realm "Overlaid"
            posted_by("Carrier") do
              office "EC1"
            end
          end
        WORLD

        dispatcher = Hecks.boot(dir, environment: "production", install_doors: false)
        world = dispatcher.registry.world("Overlaid")

        expect(world.realm).to eq("Overlaid")
        expect(world.for_verb("posted_by")).to include(adapter: "Carrier", office: "EC1")
      end
    end
  end

  describe "attaches ... from: :vendor" do
    # One real boot over a vendored package's own bluebook plus a consumer
    # hecksagon; the three expects each inspect a different facet of that
    # same successful boot (registry contents, recorded vendor list, vendor
    # dir on disk) — splitting would re-pay the two-file-write-and-boot
    # setup three times to prove nothing more than this one boot already
    # does.
    # rubocop:disable-next RSpec/ExampleLength
    it "loads every .bluebook file a vendored package declares, sorted, from the registry's own root" do
      Dir.mktmpdir do |root|
        vendor_dir = File.join(root, "vendor", "embryonaut_bluebooks", "widgets", "bluebook")
        write(root, "vendor/embryonaut_bluebooks/widgets/bluebook/widget.bluebook", <<~BLUEBOOK)
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

        domain_dir = File.join(root, "bluebook")
        write(root, "bluebook/consumer.hecksagon", <<~HECKSAGON)
          Hecks.hecksagon "Widgets" do
            attaches "widgets", from: :vendor
            attaches "Governance"
            Widgets::Widget.persisted_by("Memory")
          end
        HECKSAGON
        write(root, "bluebook/context_map.hecksagon", InMemoryDomain::GOVERNANCE_MEMORY_HECKSAGON)

        dispatcher = Hecks.boot(domain_dir, install_doors: false)

        expect(dispatcher.registry.bluebook("Widgets")).not_to be_nil
        expect(dispatcher.registry.hecksagon("Widgets").vendored_packages).to eq(["widgets"])
        expect(File.directory?(vendor_dir)).to be true
      end
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

require "spec_helper"
require "tmpdir"

# RECOVERED, then GENERALIZED — see Runtime::Loader.boot's own comment
# for the full provenance: `environment:` and `uses_embryonaut_bluebook`
# existed on a prior commit of this repo (933d1dd), were vendored out to
# a real consumer (lifeadelics/domain), and were then lost from this
# repo's own reachable history entirely — no branch here reached that
# commit. Ported forward from the consumer's vendor snapshot (the only
# surviving copy), reworked against current main's own Hecksagon/World
# shape rather than copied wholesale, since the two trees had otherwise
# diverged independently for weeks. This spec is the end-to-end proof
# the recovery actually works against a real boot, not just against the
# builder in isolation — dsl_spec.rb covers the builder-level surface.
RSpec.describe "environment overlays and vendored bluebooks" do
  def write(dir, relative, content)
    path = File.join(dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  # A MINIMAL REAL DOMAIN, ONE COMMAND, ONE ROLE — just enough to prove
  # the ungoverned-role check runs correctly against the MERGED
  # hecksagon, which is the actual regression this recovery fixes (see
  # Registry::Verification#refuse_ungoverned_roles!'s own comment).
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
            uses_framework "Governance"
            Overlaid::Thing.persisted_by("Memory")
          end
        HECKSAGON
        write(dir, "environments/production.hecksagon", <<~HECKSAGON)
          Hecks.hecksagon "Overlaid" do
            subscribe "SomeOutsideEvent"
          end
        HECKSAGON

        dispatcher = Hecks.boot(dir, environment: "production", install_facade: false)
        hexagon = dispatcher.registry.hecksagon("Overlaid")

        expect(hexagon.subscriptions).to eq(["SomeOutsideEvent"])
        expect(hexagon.bind_for("Thing", "persisted_by").adapter).to eq("Memory")
      end
    end

    it "checks the ungoverned-role refusal against the MERGED hecksagon, not each block alone" do
      Dir.mktmpdir do |dir|
        write(dir, "overlaid.bluebook", bluebook_source(role: "Someone"))
        # BASE DECLARES NO Governance — an overlay-only `uses_framework
        # "Governance"` must still be enough. Checking each block in
        # isolation (the pre-recovery behavior) would refuse the BASE
        # block here even though the final, merged hecksagon is fine.
        write(dir, "overlaid.hecksagon", <<~HECKSAGON)
          Hecks.hecksagon "Overlaid" do
            Overlaid::Thing.persisted_by("Memory")
          end
        HECKSAGON
        write(dir, "environments/production.hecksagon", <<~HECKSAGON)
          Hecks.hecksagon "Overlaid" do
            uses_framework "Governance"
          end
        HECKSAGON

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
          .to raise_error(Hecks::Runtime::WiringError, /never uses_framework "Governance"/)
      end
    end
  end

  describe "environment: overlay (World)" do
    it "merges an environments/<name>.world overlay's settings into the base rather than replacing them" do
      Dir.mktmpdir do |dir|
        write(dir, "overlaid.bluebook", bluebook_source(role: "Someone"))
        write(dir, "overlaid.hecksagon", <<~HECKSAGON)
          Hecks.hecksagon "Overlaid" do
            uses_framework "Governance"
            Overlaid::Thing.persisted_by("Memory")
          end
        HECKSAGON
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

        dispatcher = Hecks.boot(dir, environment: "production", install_facade: false)
        world = dispatcher.registry.world("Overlaid")

        expect(world.realm).to eq("Overlaid")
        expect(world.for_verb("posted_by")).to include(adapter: "Carrier", office: "EC1")
      end
    end
  end

  describe "uses_embryonaut_bluebook" do
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
            uses_embryonaut_bluebook "widgets"
            uses_framework "Governance"
            Widgets::Widget.persisted_by("Memory")
          end
        HECKSAGON

        dispatcher = Hecks.boot(domain_dir, install_facade: false)

        expect(dispatcher.registry.bluebook("Widgets")).not_to be_nil
        expect(dispatcher.registry.hecksagon("Widgets").vendored_bluebooks).to eq(["widgets"])
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

require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/fuzzing"

# `IsolatedBoot` copies a target's domain directory into a tmpdir and boots the
# copy. A hecksagon's `uses_embryonaut_bluebook "<name>"` loads from
# `<root>/vendor/embryonaut_bluebooks/<name>/bluebook`, where the root is the
# parent of the directory booted, so the copy has to carry the packages the
# hecksagons name and nothing else from `vendor/`.
RSpec.describe Hecks::Fuzzing::IsolatedBoot do
  WIDGETS_BLUEBOOK = <<~BLUEBOOK.freeze
    Hecks.bluebook "Widgets" do
      vision "a vendored package"
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

  def write(root, relative, content)
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def consumer_hecksagon(*uses)
    lines = uses.map { |name| %(  uses_embryonaut_bluebook "#{name}") }
    <<~HECKSAGON
      Hecks.hecksagon "Widgets" do
      #{lines.join("\n")}
        uses_framework "Governance"
        Widgets::Widget.persisted_by("Memory")
      end
    HECKSAGON
  end

  def project(root, uses:, vendored: %w[widgets])
    write(root, "bluebook/consumer.hecksagon", consumer_hecksagon(*uses))
    write(root, "bluebook/context_map.hecksagon", InMemoryDomain::GOVERNANCE_MEMORY_HECKSAGON)
    vendored.each do |name|
      write(root, "vendor/embryonaut_bluebooks/#{name}/bluebook/#{name}.bluebook", WIDGETS_BLUEBOOK)
    end
    File.join(root, "bluebook")
  end

  describe ".call, for a target that vendors a bluebook" do
    it "boots the copy past the vendored package" do
      Dir.mktmpdir do |root|
        domain = project(root, uses: %w[widgets])

        booted = described_class.call(domain) do |copy|
          Hecks.boot(copy, install_facade: false).registry.bluebook("Widgets")
        end

        expect(booted).not_to be_nil
      end
    end

    it "carries only the packages a hecksagon names" do
      Dir.mktmpdir do |root|
        domain = project(root, uses: %w[widgets], vendored: %w[widgets gadgets])
        write(root, "vendor/embryonaut_console/keep_out.txt", "not a bluebook package")

        vendor = described_class.call(domain) do |copy|
          Dir.glob(File.join(File.dirname(copy), "vendor", "*", "*")).map { |path| path.split("vendor/").last }
        end

        expect(vendor).to eq(["embryonaut_bluebooks/widgets"])
      end
    end

    it "carries every package the hecksagons name" do
      Dir.mktmpdir do |root|
        domain = project(root, uses: %w[widgets gadgets], vendored: %w[widgets gadgets extras])

        vendor = described_class.call(domain) do |copy|
          Dir.children(File.join(File.dirname(copy), "vendor", "embryonaut_bluebooks")).sort
        end

        expect(vendor).to eq(%w[gadgets widgets])
      end
    end

    it "leaves a named package the source root lacks to the boot's own error" do
      Dir.mktmpdir do |root|
        domain = project(root, uses: %w[widgets], vendored: [])

        expect { described_class.call(domain) { |copy| Hecks.boot(copy, install_facade: false) } }
          .to raise_error(Hecks::Runtime::WiringError, /no vendored embryonaut bluebook named "widgets"/)
      end
    end
  end

  describe ".call, for a target that vendors nothing" do
    it "copies no vendor directory when the hecksagons name no package" do
      Dir.mktmpdir do |root|
        write(root, "bluebook/consumer.hecksagon", "Hecks.hecksagon(\"Widgets\") { }\n")
        write(root, "vendor/embryonaut_bluebooks/widgets/bluebook/widgets.bluebook", WIDGETS_BLUEBOOK)

        present = described_class.call(File.join(root, "bluebook")) do |copy|
          File.exist?(File.join(File.dirname(copy), "vendor"))
        end

        expect(present).to be(false)
      end
    end

    it "does not fail on a project that has no vendor directory at all" do
      Dir.mktmpdir do |root|
        write(root, "bluebook/consumer.hecksagon", consumer_hecksagon("widgets"))

        expect { described_class.call(File.join(root, "bluebook")) { |copy| copy } }.not_to raise_error
      end
    end
  end
end

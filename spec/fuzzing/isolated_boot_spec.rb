require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/fuzzing"
require_relative "../support/postgres_probe"

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

  # `Folder#load_domain` globs `*.world` in one directory, so a directory holding two
  # `.hecksagon` files (a domain plus its `context_map.hecksagon`) needs one world file
  # naming every block in both — the second file's write must not replace the first's.
  describe ".write_worlds!" do
    def world_text(name) = %(Hecks.world "#{name}" do\nend\n)

    it "writes one world naming every hecksagon block in a directory, across files" do
      Dir.mktmpdir do |copy|
        write(copy, "bluebook/main.hecksagon", %(Hecks.hecksagon "Main" do\nend\n))
        write(copy, "bluebook/context_map.hecksagon", %(Hecks.hecksagon "Governance" do\nend\n))

        described_class.write_worlds!(copy, "fuzz.world") { |name| world_text(name) }

        text = File.read(File.join(copy, "bluebook/fuzz.world"))
        expect(text.scan(/Hecks\.world "([^"]+)"/).flatten).to contain_exactly("Main", "Governance")
      end
    end

    it "names a block declared in two files of the directory once" do
      Dir.mktmpdir do |copy|
        write(copy, "bluebook/a.hecksagon", %(Hecks.hecksagon "Shared" do\nend\n))
        write(copy, "bluebook/b.hecksagon", %(Hecks.hecksagon "Shared" do\nend\n))

        described_class.write_worlds!(copy, "fuzz.world") { |name| world_text(name) }

        expect(File.read(File.join(copy, "bluebook/fuzz.world")).scan("Hecks.world").size).to eq(1)
      end
    end

    it "keeps each directory's world to that directory's own blocks" do
      Dir.mktmpdir do |copy|
        write(copy, "bluebook/main.hecksagon", %(Hecks.hecksagon "Main" do\nend\n))
        write(copy, "nested/bluebook/inner.hecksagon", %(Hecks.hecksagon "Inner" do\nend\n))

        described_class.write_worlds!(copy, "fuzz.world") { |name| world_text(name) }

        expect(File.read(File.join(copy, "bluebook/fuzz.world"))).not_to include("Inner")
        expect(File.read(File.join(copy, "nested/bluebook/fuzz.world"))).to include("Inner")
      end
    end

    it "deletes every world the copy shipped with" do
      Dir.mktmpdir do |copy|
        write(copy, "bluebook/main.hecksagon", %(Hecks.hecksagon "Main" do\nend\n))
        write(copy, "bluebook/deployed.world", world_text("Main"))

        described_class.write_worlds!(copy, "fuzz.world") { |name| world_text(name) }

        expect(Dir.children(File.join(copy, "bluebook")).sort).to eq(%w[fuzz.world main.hecksagon])
      end
    end
  end

  # The `qa` domain keeps Governance in `context_map.hecksagon` and QualityControl in
  # `quality_control.hecksagon`, side by side; every Postgres-bound boot of it needs a
  # `database` for both. Real Postgres, because the refusal this guards is raised when the
  # adapter is built.
  describe ".call with adapter: :postgres, for a directory holding two hecksagons", :io do
    it "boots the qa domain with a database for every block" do
      skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

      qa = File.join(InMemoryDomain::ROOT, "qa")
      expect do
        described_class.call(qa, adapter: :postgres) { |copy| Hecks.boot(copy, install_facade: false) }
      end.not_to raise_error
    end
  end
end

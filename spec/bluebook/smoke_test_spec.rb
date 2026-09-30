require "spec_helper"
require "hecks/bluebook/smoke_test"
require "tmpdir"

RSpec.describe Hecks::Bluebook::SmokeTest do
  around do |example|
    @root = Dir.mktmpdir("hecks-smoke-")
    example.run
  ensure
    FileUtils.remove_entry(@root) if @root
  end

  def write_domain(domain, body, realm: "Acme")
    directory = File.join(@root, domain, "bluebook")
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, "#{domain}.bluebook"), "Hecks.bluebook #{domain.inspect} do\n#{body}\nend\n")
    File.write(File.join(directory, "#{domain}.world"), "Hecks.world #{domain.inspect} do\n  realm #{realm.inspect}\nend\n")
    File.join(@root, domain)
  end

  it "dispatches cleanly against a real, well-formed domain — no failures" do
    dir = write_domain("SmokeWidget", <<~RUBY)
      aggregate "Item" do
        identified_by :name
        attribute :name, Name
        value_object "Name" do
          attribute :value, String
        end
        command "Add" do
          attribute :name, Name
        end
      end
    RUBY

    expect(described_class.call(dir)).to eq([])
  end

  # A command acting on an existing record without `reference_to Item` looks creating.
  # It reloads and checks clean, and only breaks when dispatched twice against one identity.
  it "catches a command wrongly classified as creating — reloads clean, only breaks on dispatch" do
    dir = write_domain("SmokeWidget", <<~RUBY)
      aggregate "Item" do
        identified_by :name
        attribute :name, Name
        value_object "Name" do
          attribute :value, String
        end
        command "Add" do
          attribute :name, Name
        end
        command "Touch" do
          attribute :name, Name
        end
      end
    RUBY

    failures = described_class.call(dir)

    expect(failures.size).to eq(1)
    expect(failures.first.command).to eq("Touch")
    expect(failures.first.error).to include("AlreadyExists")
  end

  it "walks aggregates in declaration order, so a later aggregate can reference an earlier one's real id" do
    dir = write_domain("SmokeWidget", <<~RUBY)
      aggregate "Item" do
        identified_by :name
        attribute :name, Name
        value_object "Name" do
          attribute :value, String
        end
        command "Add" do
          attribute :name, Name
        end
      end

      aggregate "Tag" do
        reference_to Item

        identified_by :item
        command "Attach" do
          reference_to Item
        end
      end
    RUBY

    expect(described_class.call(dir)).to eq([])
  end

  it "reports nothing for an empty directory with no discoverable domain" do
    dir = File.join(@root, "empty")
    FileUtils.mkdir_p(dir)

    expect(described_class.call(dir)).to eq([])
  end

  # A synthesized command once collided with a real record in a file-backed store. This proves a
  # Heki-bound record survives a smoke run, whatever `.hecksagon` and `.world` bind to.
  # One example on purpose: splitting the boot and reboot comparison would lose the claim.
  # rubocop:disable-next RSpec/ExampleLength
  it "never touches the target directory's own real persisted data, however it's really bound" do
    dir = write_domain("SmokeWidget", <<~RUBY)
      aggregate "Item" do
        identified_by :name
        attribute :name, Name
        value_object "Name" do
          attribute :value, String
        end
        command "Add" do
          attribute :name, Name
        end
      end
    RUBY
    File.write(File.join(dir, "bluebook", "SmokeWidget.hecksagon"), <<~RUBY)
      Hecks.hecksagon "SmokeWidget" do
        SmokeWidget::Item.persisted_by("Heki")
      end
    RUBY
    File.write(File.join(dir, "bluebook", "SmokeWidget.world"), <<~RUBY)
      Hecks.world "SmokeWidget" do
        realm "Acme"
        persisted_by("Heki") { dir "data" }
      end
    RUBY

    real_runtime = Hecks.boot(dir, install_doors: false)
    real_runtime.dispatch_flat("SmokeWidget::Item.Add", name: { value: "smoke-test" })
    repository = real_runtime.registry.repository("SmokeWidget", real_runtime.registry.bluebook("SmokeWidget").aggregate("Item"))
    expect(repository.all.size).to eq(1)

    described_class.call(dir)

    # A fresh boot re-reads the Heki file from disk instead of trusting in-memory objects.
    reread = Hecks.boot(dir, install_doors: false)
    reread_repository = reread.registry.repository("SmokeWidget", reread.registry.bluebook("SmokeWidget").aggregate("Item"))
    expect(reread_repository.all.map(&:id)).to eq(["smoke-test"])
  end
end

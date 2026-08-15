require "spec_helper"
require "hecksagain/bluebook/smoke_test"
require "tmpdir"

RSpec.describe Hecksagain::Bluebook::SmokeTest do
  around do |example|
    @root = Dir.mktmpdir("hecksagain-smoke-")
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
    dir = write_domain("Widget", <<~RUBY)
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

  # THE EXACT SHAPE THIS TOOL WAS BUILT FOR — a command that ACTS ON an
  # existing record but never says so (`reference_to Item` missing),
  # which makes it look CREATING instead. Reloads clean, checks clean —
  # only breaks once dispatched twice against the same identity, the
  # same class of bug this tool caught for real in `bin/interview`'s
  # own build.
  it "catches a command wrongly classified as creating — reloads clean, only breaks on dispatch" do
    dir = write_domain("Widget", <<~RUBY)
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
    dir = write_domain("Widget", <<~RUBY)
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

  # THE SAFETY PROPERTY THIS TOOL EXISTS TO GUARANTEE — measured against
  # a real collision, not assumed: pointed at `examples/pizzas` (a real,
  # file-backed store carrying real accumulated records), a synthesized
  # `CreatePizza` collided with an actual pre-existing record. This
  # domain reproduces the same shape — a REAL Heki-bound aggregate with
  # a real record already in it — and proves that record survives a
  # smoke-test run untouched, regardless of what `dir`'s own `.hecksagon`
  # and `.world` actually bind to.
  it "never touches the target directory's own real persisted data, however it's really bound" do
    dir = write_domain("Widget", <<~RUBY)
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
    File.write(File.join(dir, "bluebook", "Widget.hecksagon"), <<~RUBY)
      Hecks.hecksagon "Widget" do
        Widget::Item.persisted_by("Heki")
      end
    RUBY
    File.write(File.join(dir, "bluebook", "Widget.world"), <<~RUBY)
      Hecks.world "Widget" do
        realm "Acme"
        persisted_by("Heki") { dir "data" }
      end
    RUBY

    real_runtime = Hecksagain.boot(dir, install_facade: false)
    real_runtime.dispatch("Widget::Item.Add", name: { value: "smoke-test" })
    repository = real_runtime.registry.repository("Widget", real_runtime.registry.bluebook("Widget").aggregate("Item"))
    expect(repository.all.size).to eq(1)

    described_class.call(dir)

    # RE-READ FROM DISK, A FRESH BOOT — not the same in-memory Ruby
    # objects, so this proves the real Heki FILE itself was untouched,
    # not merely that a stale reference still looks right.
    reread = Hecksagain.boot(dir, install_facade: false)
    reread_repository = reread.registry.repository("Widget", reread.registry.bluebook("Widget").aggregate("Item"))
    expect(reread_repository.all.map(&:id)).to eq(["smoke-test"])
  end
end

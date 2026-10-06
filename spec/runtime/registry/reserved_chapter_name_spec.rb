require "hecks"
require "tmpdir"

# ADR 0080, section 9: `Hecks` is the gem's own chapter name, so `verify!` refuses a client
# chapter that takes it and leaves the gem's chapter and every other name alone.
RSpec.describe "the reserved chapter name Hecks, checked at verify!" do
  GEM_CHAPTER_ROOT = File.expand_path("../../../lib/hecks/hecks", __dir__)

  CLIENT_BLUEBOOK_TEMPLATE = <<~'RUBY'.freeze
    Hecks.bluebook "%<name>s" do
      %<nest>saggregate "Widget" do
        description "A widget."
        attribute :reference, Reference
        identified_by :reference

        value_object "Reference" do
          attribute :value, String, pattern: '[^ \t\n\r]'
          invariant("a reference is present") { !value.to_s.empty? }
        end
      end
    end
  RUBY

  around do |example|
    Dir.mktmpdir do |tmp|
      @dir = tmp
      example.run
    end
  end

  attr_reader :dir

  def client_bluebook(name, namespace: nil)
    path = File.join(dir, "client.bluebook")
    nest = namespace ? %(namespace "#{namespace}"\n  ) : ""
    File.write(path, format(CLIENT_BLUEBOOK_TEMPLATE, name: name, nest: nest))
    path
  end

  # Boots `directory` as a client project; `verify!` runs inside the boot.
  def boot(directory) = Hecks.boot(directory, install_doors: false)

  it "refuses a client chapter named Hecks and names the word, the file and the fix", :aggregate_failures do
    path = client_bluebook("Hecks", namespace: "ClientHecks")

    expect { boot(dir) }.to raise_error(Hecks::Runtime::WiringError) { |error|
      expect(error.message).to include('"Hecks" is a reserved word', "Rename the chapter", path)
    }
  end

  it "refuses a Hecks chapter that no file declared" do
    registry = boot(GEM_CHAPTER_ROOT).registry
    registry.bluebook_sources.clear

    expect { registry.verify! }.to raise_error(Hecks::Runtime::WiringError, /reserved/)
  end

  it "boots the gem's own Hecks chapter" do
    expect(boot(GEM_CHAPTER_ROOT).registry.bluebooks.keys).to include("Hecks")
  end

  it "boots a differently named client chapter" do
    client_bluebook("Hecksy")

    expect(boot(dir).registry.bluebooks.keys).to eq(["Hecksy"])
  end

  it "leaves the Hecks::Domain namespace working for a chapter under another name" do
    client_bluebook("Widgets", namespace: "Hecks::Domain")

    expect(boot(dir).registry.bluebook("Widgets").namespace).to eq("Hecks::Domain")
  end
end

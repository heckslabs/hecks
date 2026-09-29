require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../../../lib/hecks/hecks/adapters/in_process_boot"

# The DomainRuntime port's adapter answers Custodian's Introspection queries without changing the
# domain it looks at (ADR 0080, section 7).
RSpec.describe Hecks::Adapters::InProcessBoot do
  BOOT_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Shelf" do
      vision "Books on a shelf."

      aggregate "Book" do
        description "A book."

        attribute :title, Title
        identified_by :title

        value_object "Title" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
          invariant("a book is titled") { !value.to_s.empty? }
        end

        lifecycle :status, default: "shelved" do
          transition "Lend" => "lent", from: "shelved"
        end

        command "Shelve" do
          attribute :title, Title
          sets :title
          emits Shelved
        end

        command "Lend", from: "shelved" do
          reference_to Book
          emits Lent
        end
      end
    end
  RUBY

  BOOT_HECKSAGON = <<~RUBY.freeze
    Hecks.hecksagon "Shelf" do
      persisted_by "Memory"
    end
  RUBY

  before(:all) do
    @dir = Dir.mktmpdir("in_process_boot")
    FileUtils.mkdir_p(File.join(@dir, "bluebook"))
    File.write(File.join(@dir, "bluebook/shelf.bluebook"), BOOT_BLUEBOOK)
    File.write(File.join(@dir, "bluebook/shelf.hecksagon"), BOOT_HECKSAGON)
  end

  after(:all) { FileUtils.rm_rf(@dir) }

  subject(:adapter) { described_class.new }

  let(:domain) { { value: @dir } }

  it "answers the IR a boot produces, as JSON, for a value-object path or a bare one" do
    expect(JSON.parse(adapter.ir(domain: domain)).fetch("Shelf")).to have_key("aggregates")
    expect(adapter.ir(domain: @dir)).to eq(adapter.ir(domain: domain))
  end

  it "answers only the translations when asked, and this domain has none" do
    expect(JSON.parse(adapter.ir(domain: domain, translations: true))).to eq([])
  end

  it "answers the language's own IR for meta" do
    expect(JSON.parse(adapter.ir(meta: true))).to have_key("Bluebook")
  end

  it "answers every aggregate's current records, and none are there yet" do
    expect(JSON.parse(adapter.stores(domain: domain))).to eq("book" => { "authoritative" => [] })
  end

  it "answers the journal, and none is there yet" do
    expect(JSON.parse(adapter.history(domain: domain))).to eq("book" => [])
  end

  it "answers the storage shape of one bluebook file, and a label per domain for a directory" do
    file = { value: File.join(@dir, "bluebook/shelf.bluebook") }

    expect(JSON.parse(adapter.shape(domain: file)).fetch("name")).to eq("Shelf")
    expect(adapter.shape(domain: { value: File.join(@dir, "bluebook") })).to match(/\AShelf \S+\z/)
  end

  it "answers a chapter's statements, one sentence a line" do
    expect(adapter.statements(domain: domain, chapter: { value: "Shelf" })).to include("A book is titled.")
  end

  it "answers the domain narrated and documented, whole or for one aggregate" do
    expect(adapter.narrate(domain: domain)).to include("Book")
    expect(adapter.narrate(domain: domain, aggregate: { value: "Book" })).to include("Book")
    expect(adapter.docs(domain: domain)).to include("Book")
    expect(adapter.docs(domain: domain, aggregate: { value: "Book" })).to include("Book")
  end

  it "refuses an aggregate that does not exist, as the projection does" do
    expect { adapter.narrate(domain: domain, aggregate: { value: "Nope" }) }.to raise_error(Hecks::Runtime::NotFound)
  end

  it "answers diagrams and the glossary as files, and writes none" do
    before = Dir.glob(File.join(@dir, "**/*")).sort

    diagrams = adapter.project_diagrams(domain: domain, chapter: { value: "Shelf" })
    glossary = adapter.glossary(domain: domain, chapter: { value: "Shelf" })

    expect(diagrams.fetch(:files)).not_to be_empty
    expect(glossary.fetch(:files).keys).to include(a_string_matching(/glossary/))
    expect(Dir.glob(File.join(@dir, "**/*")).sort).to eq(before)
  end

  it "refuses a domain or chapter that cannot be found" do
    expect { adapter.stores(domain: { value: "/no/such/domain" }) }.to raise_error(Hecks::Runtime::NotFound, /no such domain/)
    expect { adapter.statements(domain: domain, chapter: { value: "Nope" }) }
      .to raise_error(Hecks::Runtime::NotFound, /no chapter named Nope/)
  end
end

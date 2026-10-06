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

  subject(:adapter) { described_class.new }

  before(:all) do
    @dir = Dir.mktmpdir("in_process_boot")
    FileUtils.mkdir_p(File.join(@dir, "bluebook"))
    File.write(File.join(@dir, "bluebook/shelf.bluebook"), BOOT_BLUEBOOK)
    File.write(File.join(@dir, "bluebook/shelf.hecksagon"), BOOT_HECKSAGON)
  end

  after(:all) { FileUtils.rm_rf(@dir) }

  let(:domain) { { value: @dir } }

  it "answers the IR a boot produces, as JSON, for a value-object path or a bare one", :aggregate_failures do
    expect(JSON.parse(adapter.ir(domain: domain).fetch(:text)).fetch("Shelf")).to have_key("aggregates")
    expect(adapter.ir(domain: @dir).fetch(:text)).to eq(adapter.ir(domain: domain).fetch(:text))
  end

  it "answers only the translations when asked, and this domain has none" do
    expect(JSON.parse(adapter.ir(domain: domain, translations: true).fetch(:text))).to eq([])
  end

  it "answers the language's own IR for meta" do
    expect(JSON.parse(adapter.ir(meta: true).fetch(:text))).to have_key("Bluebook")
  end

  it "answers every aggregate's current records, and none are there yet" do
    expect(JSON.parse(adapter.stores(domain: domain).fetch(:text))).to eq("book" => { "authoritative" => [] })
  end

  it "answers the journal, and none is there yet" do
    expect(JSON.parse(adapter.history(domain: domain).fetch(:text))).to eq("book" => [])
  end

  it "answers the storage shape of one bluebook file, and a label per domain for a directory", :aggregate_failures do
    file = { value: File.join(@dir, "bluebook/shelf.bluebook") }

    expect(JSON.parse(adapter.shape(domain: file).fetch(:text)).fetch("name")).to eq("Shelf")
    expect(adapter.shape(domain: { value: File.join(@dir, "bluebook") }).fetch(:text)).to match(/\AShelf \S+\z/)
  end

  it "answers a chapter's statements, one sentence a line" do
    expect(adapter.statements(domain: domain, chapter: { value: "Shelf" }).fetch(:text)).to include("A book is titled.")
  end

  it "answers the domain narrated and documented, whole or for one aggregate", :aggregate_failures do
    expect(adapter.narrate(domain: domain).fetch(:text)).to include("Book")
    expect(adapter.narrate(domain: domain, aggregate: { value: "Book" }).fetch(:text)).to include("Book")
    expect(adapter.docs(domain: domain).fetch(:text)).to include("Book")
    expect(adapter.docs(domain: domain, aggregate: { value: "Book" }).fetch(:text)).to include("Book")
  end

  it "refuses an aggregate that does not exist, as the projection does" do
    expect { adapter.narrate(domain: domain, aggregate: { value: "Nope" }) }.to raise_error(Hecks::Runtime::NotFound)
  end

  context "with the diagrams and the glossary" do
    let(:diagrams) { adapter.project_diagrams(domain: domain, chapter: { value: "Shelf" }) }
    let(:glossary) { adapter.glossary(domain: domain, chapter: { value: "Shelf" }) }

    it "answers diagrams as files", :aggregate_failures do
      expect(diagrams).not_to be_empty
      expect(diagrams).to all(include(:name, :text))
    end

    it "answers the glossary as a file" do
      expect(glossary.map { |file| file.fetch(:name) }).to include(a_string_matching(/glossary/))
    end

    it "writes none" do
      before = Dir.glob(File.join(@dir, "**/*"))

      [diagrams, glossary]

      expect(Dir.glob(File.join(@dir, "**/*"))).to eq(before)
    end
  end

  context "with a generated sequence" do
    let(:script) { JSON.parse(adapter.generate_sequence(domain: domain, seed: 3, steps: 5).fetch(:text)) }

    it "answers one generated sequence as a replayable script", :aggregate_failures do
      expect(script.fetch("name")).to eq("#{File.basename(@dir)}-generated")
      expect(script.fetch("note")).to include("seed 3, 5 steps requested")
      expect(script.fetch("steps")).to all(include("verb"))
    end

    it "answers the same one for the same seed" do
      expect(adapter.generate_sequence(domain: domain, seed: 3, steps: 5).fetch(:text))
        .to eq(adapter.generate_sequence(domain: @dir, seed: 3, steps: 5).fetch(:text))
    end
  end

  def absent_domain = File.join(Dir.tmpdir, "hecks-absent-#{Process.pid}", "no/such/domain")

  it "generates from seed 1 and 30 steps unless told otherwise" do
    expect(JSON.parse(adapter.generate_sequence(domain: domain).fetch(:text)).fetch("note")).to include("seed 1, 30 steps")
  end

  it "refuses to generate for a missing domain" do
    expect { adapter.generate_sequence(domain: { value: absent_domain }) }
      .to raise_error(Hecks::Runtime::NotFound, /no such domain/)
  end

  it "refuses a domain that cannot be found" do
    expect { adapter.stores(domain: { value: absent_domain }) }.to raise_error(Hecks::Runtime::NotFound, /no such domain/)
  end

  it "refuses a chapter that cannot be found" do
    expect { adapter.statements(domain: domain, chapter: { value: "Nope" }) }
      .to raise_error(Hecks::Runtime::NotFound, /no chapter named Nope/)
  end
end

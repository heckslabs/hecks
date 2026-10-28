require "spec_helper"
require "json"
require "open3"
require "tmpdir"
require "hecks/composer"
require_relative "support/hecks_parse_binary"

# A bluebook written as plain sentences and the same bluebook written in the Ruby form are one
# chapter: `hecks-parse` reads the sentences into the IR Ruby builds from the Ruby form, and the
# Ruby text it renders from them builds that IR again when Ruby loads it.
RSpec.describe "a bluebook written as sentences", :io do
  include_context "with the hecks-parse binary"

  PAIRS_ROOT = File.expand_path("fixtures/sentence", __dir__)
  PAIRS = Dir.glob(File.join(PAIRS_ROOT, "*", "sentence_form.bluebook")).freeze

  let(:scratch) { Dir.mktmpdir }

  after { FileUtils.remove_entry(scratch) }

  # The IR Ruby builds from `path`, as the parity spec prints it.
  def ruby_ir(path, chapter)
    registry = Hecks::Runtime::Registry.new(root: File.dirname(path, 2))
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      InMemoryDomain.load_bluebook_files([path])
    end
    "#{JSON.pretty_generate(Hecks::Projector::Exporter.call(registry).fetch(chapter))}\n"
  end

  def parse(*args)
    Open3.capture3(Hecks::Composer::Parse.binary, *args)
  end

  def chapter_of(path) = Hecks::Composer::Parse.chapter_name(path)

  def twin_of(sentence_file) = File.join(File.dirname(sentence_file), "ruby_form.bluebook")

  # Writes `text` under the scratch directory and answers its path.
  def write_file(relative, text)
    path = File.join(scratch, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  # A registry rooted in the scratch directory, with every bluebook under `folder` loaded.
  def registry_loading(folder)
    registry = Hecks::Runtime::Registry.new(root: scratch)
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Hecks::Adapters::Folder.new.load_bluebooks(folder)
    end
    registry
  end

  # The names of the aggregates the Ruby form of `sentence_file` declares.
  def twin_aggregates(sentence_file)
    ir = JSON.parse(ruby_ir(twin_of(sentence_file), chapter_of(sentence_file)))
    ir.fetch("aggregates").map { |aggregate| aggregate.fetch("name") }
  end

  it "has at least one pair to compare" do
    expect(PAIRS).not_to be_empty
  end

  describe "a file's first line" do
    let(:sentence) { write_file("a.bluebook", "\n# a note\nDomain: Orders\n") }
    let(:ruby) { write_file("b.bluebook", "Hecks.bluebook \"Orders\" do\nend\n") }

    it "marks a sentence file by its Domain line, past blank lines and comments" do
      expect(Hecks::SentenceForm.sentences?(sentence)).to be(true)
    end

    it "does not mistake the Ruby form for sentences" do
      expect(Hecks::SentenceForm.sentences?(ruby)).to be(false)
    end

    it "names the bluebook after the Domain line" do
      expect(Hecks::SentenceForm.chapter_name(sentence)).to eq("Orders")
    end
  end

  it "refuses a sentence it does not know in the parser's own words, with the line and column" do
    path = write_file("bluebook/orders.bluebook", "Domain: Orders\n\nAggregate: Order\n  An order.\n  Whenever it rains\n")

    expect { registry_loading(File.dirname(path)) }
      .to raise_error(Hecks::SentenceForm::Refused, /orders\.bluebook:5:3: this is not a sentence I know in an aggregate/)
  end

  PAIRS.each do |sentence_file|
    describe File.basename(File.dirname(sentence_file)) do
      it "reads the bluebook name off its Domain line" do
        expect(chapter_of(sentence_file)).to eq(chapter_of(twin_of(sentence_file)))
      end

      it "lowers to the byte-identical ir.json Ruby builds from the Ruby form", :aggregate_failures do
        out, err, status = parse("chapter", "--chapter", chapter_of(sentence_file), sentence_file)

        expect(status).to be_success, err
        expect(out).to eq(ruby_ir(twin_of(sentence_file), chapter_of(sentence_file)))
      end

      it "is exactly what the formatter writes for the Ruby form", :aggregate_failures do
        out, err, status = parse("format", "--chapter", chapter_of(twin_of(sentence_file)), twin_of(sentence_file))

        expect(status).to be_success, err
        expect(out).to eq(File.read(sentence_file))
      end

      it "is read as the same bluebook by the corpus" do
        expect(Hecks::Corpus.chapter_name_of(sentence_file)).to eq(chapter_of(twin_of(sentence_file)))
      end

      it "loads through the Folder adapter like any bluebook, as the same aggregates" do
        copy = write_file("bluebook/page.bluebook", File.read(sentence_file))
        registry = registry_loading(File.dirname(copy))

        expect(registry.bluebook(chapter_of(sentence_file)).aggregates.map(&:hecks_name)).to eq(twin_aggregates(sentence_file))
      end

      it "records the file the author wrote as the chapter's source" do
        copy = write_file("bluebook/page.bluebook", File.read(sentence_file))
        registry = registry_loading(File.dirname(copy))

        expect(registry.bluebook_sources[chapter_of(sentence_file)]).to eq([copy])
      end

      it "renders Ruby text that builds that same IR when Ruby loads it" do
        text, err, status = parse("render", "--chapter", chapter_of(sentence_file), sentence_file)
        raise err unless status.success?

        rendered = write_file("bluebook/rendered.bluebook", text)
        expect(ruby_ir(rendered, chapter_of(sentence_file))).to eq(ruby_ir(twin_of(sentence_file), chapter_of(sentence_file)))
      end
    end
  end
end

require "spec_helper"
require "json"
require "open3"
require "tmpdir"
require "hecks/composer"
require_relative "support/hecks_parse_binary"

# A chapter written as plain sentences and the same chapter written in the Ruby form are one
# chapter: `hecks-parse` reads the sentences into the IR Ruby builds from the Ruby form, and the
# Ruby text it renders from them builds that IR again when Ruby loads it.
RSpec.describe "a chapter written as sentences", :io do
  include_context "with the hecks-parse binary"

  PAIRS_ROOT = File.expand_path("fixtures/sentence", __dir__)
  PAIRS = Dir.glob(File.join(PAIRS_ROOT, "*", "sentence_form.bluebook")).sort.freeze

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

  it "has at least one pair to compare" do
    expect(PAIRS).not_to be_empty
  end

  it "recognises a sentence file by its Domain line, past blank lines and comments" do
    Dir.mktmpdir do |dir|
      sentence = File.join(dir, "a.bluebook")
      File.write(sentence, "\n# a note\nDomain: Orders\n")
      ruby = File.join(dir, "b.bluebook")
      File.write(ruby, "Hecks.bluebook \"Orders\" do\nend\n")

      expect(Hecks::SentenceForm.sentences?(sentence)).to be(true)
      expect(Hecks::SentenceForm.sentences?(ruby)).to be(false)
      expect(Hecks::SentenceForm.chapter_name(sentence)).to eq("Orders")
    end
  end

  it "refuses a sentence it does not know in the parser's own words, with the line and column" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "bluebook", "orders.bluebook")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "Domain: Orders\n\nAggregate: Order\n  An order.\n  Whenever it rains\n")
      registry = Hecks::Runtime::Registry.new(root: dir)

      expect do
        Hecks.with_registry(registry) do
          MemoryPorts.load!
          Hecks::Adapters::Folder.new.load_bluebooks(File.dirname(path))
        end
      end.to raise_error(Hecks::SentenceForm::Refused, /orders\.bluebook:5:3: this is not a sentence I know in an aggregate/)
    end
  end

  PAIRS.each do |sentence_file|
    name = File.basename(File.dirname(sentence_file))
    ruby_file = File.join(File.dirname(sentence_file), "ruby_form.bluebook")

    describe name do
      it "reads the chapter name off its Domain line" do
        expect(chapter_of(sentence_file)).to eq(chapter_of(ruby_file))
      end

      it "lowers to the byte-identical ir.json Ruby builds from the Ruby form" do
        chapter = chapter_of(sentence_file)
        out, err, status = parse("chapter", "--chapter", chapter, sentence_file)

        expect(status).to be_success, err
        expect(out).to eq(ruby_ir(ruby_file, chapter))
      end

      it "is exactly what the formatter writes for the Ruby form" do
        chapter = chapter_of(ruby_file)
        out, err, status = parse("format", "--chapter", chapter, ruby_file)

        expect(status).to be_success, err
        expect(out).to eq(File.read(sentence_file))
      end

      it "is read as the same chapter by the corpus" do
        expect(Hecks::Corpus.chapter_name_of(sentence_file)).to eq(chapter_of(ruby_file))
      end

      it "loads through the Folder adapter like any bluebook, under the file the author wrote" do
        chapter = chapter_of(sentence_file)
        Dir.mktmpdir do |dir|
          copy = File.join(dir, "bluebook", "page.bluebook")
          FileUtils.mkdir_p(File.dirname(copy))
          FileUtils.cp(sentence_file, copy)
          registry = Hecks::Runtime::Registry.new(root: dir)
          Hecks.with_registry(registry) do
            MemoryPorts.load!
            Hecks::Adapters::Folder.new.load_bluebooks(File.dirname(copy))
          end

          twin = JSON.parse(ruby_ir(ruby_file, chapter)).fetch("aggregates").map { |aggregate| aggregate.fetch("name") }
          expect(registry.bluebook(chapter).aggregates.map(&:hecks_name)).to eq(twin)
          expect(registry.bluebook_sources[chapter]).to eq([copy])
        end
      end

      it "renders Ruby text that builds that same IR when Ruby loads it" do
        chapter = chapter_of(sentence_file)
        text, err, status = parse("render", "--chapter", chapter, sentence_file)
        expect(status).to be_success, err

        Dir.mktmpdir do |dir|
          rendered = File.join(dir, "bluebook", "rendered.bluebook")
          FileUtils.mkdir_p(File.dirname(rendered))
          File.write(rendered, text)

          expect(ruby_ir(rendered, chapter)).to eq(ruby_ir(ruby_file, chapter))
        end
      end
    end
  end
end

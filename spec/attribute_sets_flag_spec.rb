require "spec_helper"
require "json"
require "open3"
require "tmpdir"
require_relative "support/hecks_parse_binary"

# `attribute :x, T, sets: true` in a command says what `attribute :x, T` followed by `sets :x`
# says: the argument, and the plain write of the owner's field of the same name.
RSpec.describe "attribute sets: true" do
  CHAPTER = <<~BLUEBOOK.freeze
    Hecks.bluebook "Shelf" do
      aggregate "Book" do
        identified_by :code
        value_object("Code") { attribute :value, String }
        value_object("Title") { attribute :value, String }
        attribute :code, Code
        attribute :title, Title

        command "Catalogue" do
          %<body>s
          emits "Catalogued"
        end
      end
    end
  BLUEBOOK

  # Yields the path of a file holding the chapter with `body` in its command.
  def chapter_file(body)
    Dir.mktmpdir("sets-flag") do |dir|
      path = File.join(dir, "shelf.bluebook")
      File.write(path, format(CHAPTER, body: body))
      yield path
    end
  end

  # The chapter as Ruby builds it.
  def exported(body)
    chapter_file(body) do |path|
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) { load_bluebook_files(path) }
      Hecks::Projector::Exporter.call(registry).fetch("Shelf")
    end
  end

  # What `hecks-parse` answers for the chapter: its output, its error and its status.
  def parsed(body)
    chapter_file(body) do |path|
      Open3.capture3(Hecks::Composer::Parse.binary, "bluebook", "--bluebook", "Shelf", path)
    end
  end

  it "builds the IR the separate sets line builds" do
    folded = exported("attribute :code, Code, sets: true\n      attribute :title, Title, sets: true")
    long = exported("attribute :code, Code\n      attribute :title, Title\n      sets :code\n      sets :title")

    expect(folded).to eq(long)
  end

  it "still allows a sets line beside it" do
    folded = exported("attribute :code, Code, sets: true\n      attribute :title, Title\n      sets :title")
    long = exported("attribute :code, Code\n      attribute :title, Title\n      sets :code\n      sets :title")

    expect(folded).to eq(long)
  end

  it "is refused when the owner has no field of that name" do
    expect { exported("attribute :isbn, Code, sets: true") }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /isbn.*sets: true.*owner declares no field/m)
  end

  it "takes only true" do
    expect { exported("attribute :code, Code, sets: :yes") }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /sets: true or no sets:/)
  end

  describe "read by hecks-parse", :io do
    include_context "with the hecks-parse binary"

    let(:body) { "attribute :code, Code, sets: true\n      attribute :title, Title, sets: true" }

    it "lowers to the IR Ruby builds", :aggregate_failures do
      out, err, status = parsed(body)

      expect(status).to be_success, err
      expect(JSON.parse(out)).to eq(JSON.parse(JSON.generate(exported(body))))
    end

    it "refuses a field the owner does not declare" do
      _, err, status = parsed("attribute :isbn, Code, sets: true")

      expect([status.success?, err]).to match([false, /isbn.*sets: true.*owner declares no field/m])
    end
  end
end

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

# Custodian's Introspection, reached the way `hecks <verb>` reaches it: the Hecks domain boots,
# the launcher resolves a query by its aggregate-qualified name, and the DomainRuntime port's adapter answers.
RSpec.describe "hecks introspection through the launcher" do
  INTROSPECTED_BLUEBOOK = <<~RUBY.freeze
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

        command "Shelve" do
          attribute :title, Title
          sets :title
          emits Shelved
        end
      end
    end
  RUBY

  INTROSPECTED_HECKSAGON = <<~RUBY.freeze
    Hecks.hecksagon "Shelf" do
      persisted_by "Memory"
    end
  RUBY

  before(:all) do
    @dir = Dir.mktmpdir("introspected")
    FileUtils.mkdir_p(File.join(@dir, "bluebook"))
    File.write(File.join(@dir, "bluebook/shelf.bluebook"), INTROSPECTED_BLUEBOOK)
    File.write(File.join(@dir, "bluebook/shelf.hecksagon"), INTROSPECTED_HECKSAGON)
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  after(:all) { FileUtils.rm_rf(@dir) }

  def run_verb(*argv)
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")
  end

  it "answers a document as its own text, not as a JSON string inside JSON", :aggregate_failures do
    out, status = run_verb("introspection.statements", @dir, "chapter=Shelf")

    expect(status).to eq(0)
    expect(out).to include("A book is titled.")
    expect(out).not_to start_with("[")
  end

  it "answers a JSON document as that JSON, byte for byte what the adapter returns", :aggregate_failures do
    out, status = run_verb("introspection.stores", @dir)

    expect(status).to eq(0)
    expect(out).to eq(Hecks::Adapters::InProcessBoot.new.stores(domain: @dir).fetch(:text))
  end

  it "answers files as rows of name and text, and writes none", :aggregate_failures do
    before = Dir.glob(File.join(@dir, "**/*"))
    out, status = run_verb("introspection.glossary", @dir, "chapter=Shelf")

    expect(status).to eq(0)
    expect(JSON.parse(out)).to all(include("name", "text"))
    expect(Dir.glob(File.join(@dir, "**/*"))).to eq(before)
  end

  it "words a missing domain as a refusal, not a backtrace", :aggregate_failures do
    out, status = Dir.mktmpdir { |scratch| run_verb("introspection.stores", File.join(scratch, "no/such/domain")) }

    expect(status).to eq(1)
    expect(out).to include("no such domain")
  end

  it "reads without writing: the Hecks domain's event log stays empty" do
    run_verb("introspection.stores", @dir)
    run_verb("introspection.narrate", @dir)

    expect(@hecks.registry.event_log.to_a).to be_empty
  end
end

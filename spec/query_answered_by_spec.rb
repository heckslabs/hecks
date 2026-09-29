require "spec_helper"
require "tmpdir"
require "fileutils"

# `answered_by "Port"` hands a query to a port's bound adapter: the answer comes from the
# adapter, the aggregate's records are never read, and nothing is written.
RSpec.describe "a query answered by a port" do
  ANSWERED_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Lookup" do
      vision "Answers come from an adapter, not from stored records."

      aggregate "Note" do
        description "A stored note."

        attribute :title, Title
        identified_by :title

        value_object "Title" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
          invariant("a note is titled") { !value.to_s.empty? }
        end

        query "Echo" do
          attribute :title, Title
          answered_by "Echoer"
        end

        query "Orphan" do
          answered_by "Nobody"
        end

        query "Recent" do
          where(title: "x")
        end

        command "Write" do
          attribute :title, Title
          sets :title
          emits Written
        end
      end
    end
  RUBY

  ANSWERED_HECKSAGON = <<~RUBY.freeze
    Hecks.hecksagon "Lookup" do
      persisted_by "Memory"
    end
  RUBY

  ANSWERED_ADAPTER = <<~RUBY.freeze
    require_relative "echoer"

    Hecks.adapter "Echoer" do
      port "Echoer"
    end
  RUBY

  ANSWERED_ADAPTER_CLASS = <<~RUBY.freeze
    module Hecks
      module Adapters
        class Echoer
          def initialize(aggregate: nil, settings: {}, root: nil); end

          def echo(title:)
            { heard: title }
          end
        end
      end
    end
  RUBY

  def boot_lookup
    dir = Dir.mktmpdir("answered_by")
    FileUtils.mkdir_p(File.join(dir, "bluebook/adapters"))
    File.write(File.join(dir, "bluebook/lookup.bluebook"), ANSWERED_BLUEBOOK)
    File.write(File.join(dir, "bluebook/lookup.hecksagon"), ANSWERED_HECKSAGON)
    File.write(File.join(dir, "bluebook/adapters/echoer.adapter"), ANSWERED_ADAPTER)
    File.write(File.join(dir, "bluebook/adapters/echoer.rb"), ANSWERED_ADAPTER_CLASS)
    [dir, Hecks.boot(dir, install_facade: false)]
  end

  before do
    @dir, @runtime = boot_lookup
  end

  after { FileUtils.rm_rf(@dir) }

  it "answers from the adapter, handing it plain data" do
    expect(@runtime.query("Lookup::Note.Echo", title: "hello")).to eq([{ heard: { value: "hello" } }])
  end

  it "reads no record and writes no event" do
    @runtime.query("Lookup::Note.Echo", title: "hello")

    expect(@runtime.registry.event_log.to_a).to be_empty
  end

  it "answers the reference oracle the same way" do
    expect(@runtime.reference_query("Lookup::Note.Echo", title: "hello"))
      .to eq(@runtime.query("Lookup::Note.Echo", title: "hello"))
  end

  it "refuses a port no adapter implements, naming the port and the query" do
    expect { @runtime.query("Lookup::Note.Orphan") }
      .to raise_error(Hecks::Runtime::WiringError, /no adapter implements the Nobody port.*Note\.Orphan/)
  end

  it "is carried in the IR as an option, and only on the query that declares it" do
    note = @runtime.registry.bluebook("Lookup").aggregates.first
    emitted = note.queries.to_h { |query| [query.name, query.to_h] }

    expect(emitted["Echo"][:answered_by]).to eq(port: "Echoer")
    expect(emitted["Recent"]).not_to have_key(:answered_by)
  end
end

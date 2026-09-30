require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/fuzzing"

# A replay checks a domain's own rules. The adapters a port or a port-answered query would reach
# run shells and write files, so a fuzz boot asks `OutsideWorld` instead and the adapter never runs.
RSpec.describe Hecks::Fuzzing::OutsideWorld do
  REACH_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Reach" do
      vision "A query an adapter answers."

      aggregate "Note" do
        description "A stored note."

        attribute :title, Title
        identified_by :title

        value_object "Title" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
          invariant("a note is titled") { !value.to_s.empty? }
        end

        value_object "Heard" do
          attribute :heard, Title
        end

        query "Echo" do
          attribute :title, Title
          returns Heard
        end

        command "Write" do
          attribute :title, Title
          sets :title
          emits Written
        end
      end
    end
  RUBY

  REACH_HECKSAGON = <<~RUBY.freeze
    Hecks.hecksagon "Reach" do
      persisted_by "Memory"

      Reach::Note.port "Echoer" do
        answers_query "Echo"
      end
    end
  RUBY

  def write_domain(dir, marker)
    FileUtils.mkdir_p(File.join(dir, "bluebook/adapters"))
    File.write(File.join(dir, "bluebook/reach.bluebook"), REACH_BLUEBOOK)
    File.write(File.join(dir, "bluebook/reach.hecksagon"), REACH_HECKSAGON)
    File.write(File.join(dir, "bluebook/adapters/reaching_echoer.adapter"), <<~RUBY)
      require_relative "reaching_echoer"

      Hecks.adapter "ReachingEchoer" do
        port "Echoer"
      end
    RUBY
    File.write(File.join(dir, "bluebook/adapters/reaching_echoer.rb"), <<~RUBY)
      module Hecks
        module Adapters
          class ReachingEchoer
            def initialize(aggregate: nil, settings: {}, root: nil); end

            def echo(title:)
              File.write(#{marker.inspect}, title)
              { heard: title }
            end
          end
        end
      end
    RUBY
  end

  around do |example|
    Dir.mktmpdir("outside-world") do |dir|
      @dir = File.join(dir, "reach")
      @marker = File.join(dir, "reached")
      write_domain(@dir, @marker)
      example.run
    end
  end

  let(:steps) { [{ "query" => "Reach::Note.Echo", "args" => { "title" => { "value" => "hello" } } }] }

  it "refuses a port-answered query in a replay, and the adapter never runs" do
    history = Hecks::Fuzzing::Replay.call(@dir, steps)

    expect(File.exist?(@marker)).to be(false)
    expect(history.fetch(:refusals).map { |refusal| refusal[:kind] }).to eq([described_class::Refused.name])
    expect(history.fetch(:refusals).first[:error]).to include("Note.Echo", "Echoer")
  end

  it "runs no adapter while a sequence is generated either" do
    Hecks::Fuzzing::SequenceGenerator.generate(@dir, seed: 1, steps: 10)

    expect(File.exist?(@marker)).to be(false)
  end

  it "leaves the adapter running for a caller that is not replaying" do
    runtime = Hecks.boot(@dir, install_doors: false)

    expect(runtime.query("Reach::Note.Echo", title: "hello")).to eq([{ heard: { value: "hello" } }])
    expect(File.exist?(@marker)).to be(true)
  end

  it "refuses as a runtime refusal that no guard description quotes" do
    expect(described_class::Refused.ancestors).to include(Hecks::Runtime::GivenNotMet)
    expect(Hecks::Fuzzing::Properties::Guards::GUARD_REFUSAL_KINDS).not_to include(described_class::Refused.name)
  end
end

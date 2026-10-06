require "spec_helper"
require "tmpdir"
require "fileutils"
require_relative "../../../lib/hecks/hecks/adapters/terminal"

# The Terminal port's adapter starts an interactive session and nowhere else does.
RSpec.describe Hecks::Adapters::Terminal do
  after { described_class.launcher = nil }

  def quietly
    saved = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = saved
  end

  it "opens the bundled pizzas domain when no domain is named, and hands the session to its launcher", :aggregate_failures do
    started = []
    described_class.launcher = -> { started << :session }

    answer = quietly { described_class.new.open }

    expect(started).to eq([:session])
    expect(answer.dig(:output, :value)).to eq("console session ended (pizzas)")
  end

  describe "#serve" do
    after { described_class.server = nil }

    context "when the server returns" do
      let(:seen) { [] }
      let(:answers) { [described_class.new.serve, described_class.new.serve(stdio: { value: true })] }

      before { described_class.server = ->(argv) { seen << argv } }

      it "hands the process to the server, with --stdio only when asked" do
        answers

        expect(seen).to eq([[], ["--stdio"]])
      end

      it "answers when it closes" do
        expect(answers.map { |answer| answer.dig(:output, :value) }).to all(eq("mcp door closed"))
      end
    end

    it "words a door that refuses to start as a failure" do
      described_class.server = ->(_argv) { exit 2 }

      expect { described_class.new.serve }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /refused to start \(status 2\)/)
    end

    it "starts the real door, whose stdio guard refuses an unknown HECKS_MCP_ variable", :aggregate_failures do
      stub_const("ENV", ENV.to_h.merge("HECKS_MCP_BOGUS" => "1"))

      expect do
        expect { described_class.new.serve(stdio: { value: true }) }
          .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /refused to start \(status 2\)/)
      end.to output(/HECKS_MCP_BOGUS/).to_stderr
    end
  end

  TERMINAL_SHELF_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Shelf" do
      vision "Books on a shelf."
      aggregate "Book" do
        description "A book."
        attribute :title, Title
        identified_by :title
        value_object("Title") { attribute :value, String }
        command("Shelve") { attribute :title, Title; sets :title; emits Shelved }
      end
    end
  RUBY

  def write_shelf_domain(dir)
    FileUtils.mkdir_p(File.join(dir, "bluebook"))
    File.write(File.join(dir, "bluebook/shelf.bluebook"), TERMINAL_SHELF_BLUEBOOK)
    File.write(File.join(dir, "bluebook/shelf.hecksagon"), %(Hecks.hecksagon "Shelf" do\n  persisted_by "Memory"\nend\n))
  end

  def open_shelf(dir)
    write_shelf_domain(dir)
    described_class.launcher = -> {}
    quietly { described_class.new.open(subject: { value: dir }) }
  end

  it "boots a named domain as it is wired" do
    Dir.mktmpdir("terminal") do |dir|
      expect(open_shelf(dir).dig(:output, :value)).to eq("console session ended (#{dir})")
    end
  end
end

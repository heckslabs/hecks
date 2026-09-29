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

  it "opens the bundled pizzas domain when no domain is named, and hands the session to its launcher" do
    started = []
    described_class.launcher = -> { started << :session }

    answer = quietly { described_class.new.open }

    expect(started).to eq([:session])
    expect(answer.dig(:output, :value)).to eq("console session ended (pizzas)")
  end

  it "boots a named domain as it is wired" do
    Dir.mktmpdir("terminal") do |dir|
      FileUtils.mkdir_p(File.join(dir, "bluebook"))
      File.write(File.join(dir, "bluebook/shelf.bluebook"), <<~RUBY)
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
      File.write(File.join(dir, "bluebook/shelf.hecksagon"), %(Hecks.hecksagon "Shelf" do\n  persisted_by "Memory"\nend\n))
      described_class.launcher = -> {}

      answer = quietly { described_class.new.open(subject: { value: dir }) }

      expect(answer.dig(:output, :value)).to eq("console session ended (#{dir})")
    end
  end
end

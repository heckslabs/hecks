require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "hecks/adapters/driving/resident/server"
require "hecks/adapters/driving/resident/client"

# The phases a traced line names beyond the launcher's own: the store it opens, the event it
# records, the reactions it settles, and the wait for a heavy slot.
RSpec.describe "the trace's marks of a write" do
  let(:marks) { Hecks::Adapters::Driving::Resident::Trace::Marks }
  let(:written) { [] }
  let(:announced) { [:event] }

  before do
    allow(Hecks::Adapters::Driving::Resident::Trace).to receive(:mark) { |name| written << name }
  end

  def stand_in(&body)
    Class.new { define_method(:react, &body) }.tap { |klass| klass.send(:private, :react) }
  end

  it "names the event recorded, then the reactions begun and settled, in that order" do
    klass = stand_in { |_events| :done }
    klass.prepend(marks::Reactions)
    klass.new.send(:react, [:event])
    expect(written).to eq(%w[event_recorded reactions_begin reactions_end])
  end

  it "names nothing for a read, which announces no event" do
    klass = stand_in { |_events| :done }
    klass.prepend(marks::Reactions)
    klass.new.send(:react, [])
    expect(written).to eq([])
  end

  def cascading
    Class.new do
      define_method(:react) { |events| events.size > 1 ? nil : react(%i[event cascade]) }
      private :react
      prepend Hecks::Adapters::Driving::Resident::Trace::Marks::Reactions
    end
  end

  it "names the reactions of a write once, not once per reaction it causes" do
    cascading.new.send(:react, [:event])
    expect(written.count("reactions_begin")).to eq(1)
  end

  it "keeps the dispatcher's reactions private" do
    klass = stand_in { |_events| :done }
    klass.prepend(marks::Reactions)
    expect(klass.private_method_defined?(:react)).to be(true)
  end

  it "attaches all of its hooks, and names any it could not" do
    expect(marks.attach).to eq(%i[reactions store_open heavy_slot])
  end

  describe "a cold boot, with no resident to fork it" do
    def ancestry(dir)
      script = File.join(dir, "hecks")
      File.write(script, 'require "hecks"; puts Hecks::Runtime::Dispatcher.ancestors.map(&:to_s)')
      env = { "HECKS_TRACE_TIMING" => "1", "PATH" => ENV.fetch("PATH"), "HOME" => Dir.home }
      Open3.capture2(env, RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), script).first
    end

    it "puts the marks on the dispatcher when the launcher asked for them" do
      Dir.mktmpdir { |dir| expect(ancestry(dir)).to include("Marks::Reactions") }
    end
  end
end

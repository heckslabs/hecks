require "spec_helper"
require "hecks/rust_build"
require "hecks/hecks/adapters/console_capture"

# `$stdout`, `$stderr` and `ENV` are process-wide, so RustBuild calls and console captures share
# one lock, and a failed call always puts what it changed back.
RSpec.describe Hecks::RustBuild do
  let(:capture) { Hecks::Adapters::ConsoleCapture }

  describe ".with_env" do
    before do
      ENV["CAPTURE_LOCK_A"] = "keep"
      ENV.delete("CAPTURE_LOCK_B")
    end

    after { ENV.delete("CAPTURE_LOCK_A") }

    it "puts back every variable it set when a later value cannot be assigned", :aggregate_failures do
      expect { described_class.with_env("CAPTURE_LOCK_A" => "changed", "CAPTURE_LOCK_B" => 5) { :never } }
        .to raise_error(TypeError)

      expect(ENV.fetch("CAPTURE_LOCK_A", nil)).to eq("keep")
      expect(ENV.key?("CAPTURE_LOCK_B")).to be(false)
    end

    it "puts variables back when the block raises", :aggregate_failures do
      expect { described_class.with_env("CAPTURE_LOCK_A" => "x") { raise "boom" } }.to raise_error("boom")

      expect(ENV.fetch("CAPTURE_LOCK_A", nil)).to eq("keep")
    end
  end

  describe ".capture" do
    before do
      stub_const("Hecks::RustBuild::TOOLS", { "broken" => ["rust_build/no_such_tool", :NoSuchTool] })
      @stdout = $stdout
    end

    it "answers a tool that cannot be loaded as a failure with the reason", :aggregate_failures do
      result = described_class.capture("broken", [])

      expect(result.status).to eq(1)
      expect(result.err).to include("broken: LoadError")
      expect($stdout).to equal(@stdout)
    end
  end

  describe "the capture lock" do
    # Starts `work` on another thread; answers the thread and a probe for whether it has finished.
    def start_waiter(&work)
      finished = false
      [Thread.new { work.call.tap { finished = true } }, -> { finished }]
    end

    def blocked_while_held(holder_lock, &work)
      entered = Queue.new
      release = Queue.new
      holder = Thread.new { holder_lock.call { entered.push(true).then { release.pop } } }
      entered.pop
      waiter, finished = start_waiter(&work)
      sleep 0.2
      blocked = !finished.call
      release << true
      [holder, waiter].each(&:join)
      blocked
    end

    it "makes a console capture wait for a RustBuild call" do
      held = ->(&work) { described_class.with_env({}, &work) }

      expect(blocked_while_held(held) { capture.capture { :x } }).to be(true)
    end

    it "makes a RustBuild call wait for a console capture" do
      held = ->(&work) { capture.capture(&work) }

      expect(blocked_while_held(held) { described_class.with_env({}) { :ok } }).to be(true)
    end

    it "lets a capture nest inside another on the same thread", :aggregate_failures do
      outcome = capture.capture { capture.capture { :inner } }

      expect(outcome.output).to eq("")
      expect(outcome.status).to eq(0)
    end

    it "puts the streams back after a capture whose block raises", :aggregate_failures do
      out = $stdout

      expect { capture.capture { raise "boom" } }.to raise_error("boom")

      expect($stdout).to equal(out)
    end
  end
end

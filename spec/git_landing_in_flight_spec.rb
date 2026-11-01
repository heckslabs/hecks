require "spec_helper"
require "hecks/hecks/adapters/git_landing"
require "tmpdir"

# The guard that keeps real git steps serial across processes.
RSpec.describe Hecks::Adapters::GitLanding::InFlight do
  let(:dir) { Dir.mktmpdir("hecks-in-flight") }

  let(:script) do
    <<~RUBY
      require "hecks/hecks/adapters/git_landing/in_flight"
      queue = Hecks::Adapters::GitLanding::InFlight.new(ARGV[0])
      begin
        queue.claim("work/" + ARGV[1])
        puts "won"
        sleep 1
      rescue Hecks::Adapters::GitLanding::InFlight::Busy
        puts "busy"
      end
    RUBY
  end

  after { FileUtils.remove_entry(dir) }

  it "lets exactly one of two concurrent attempts through", :aggregate_failures do
    outcomes = Array.new(2) { |n| Thread.new { attempt(n) } }.map(&:value)

    expect(outcomes.count { |outcome| outcome.is_a?(described_class::Claim) }).to eq(1)
    expect(outcomes).to include(described_class::Busy)
  end

  def attempt(number)
    described_class.new(dir).claim("work/#{number}")
  rescue described_class::Busy
    described_class::Busy
  end

  def contender(number)
    IO.popen(["ruby", "-I", File.expand_path("../lib", __dir__), "-e", script, dir, number.to_s], &:read).strip
  end

  it "lets exactly one of several processes through" do
    outcomes = Array.new(4) { |n| Thread.new { contender(n) } }.map(&:value)

    expect(outcomes.tally).to eq("won" => 1, "busy" => 3)
  end

  it "frees the queue on release, and only for the holder", :aggregate_failures do
    first = described_class.new(dir).claim("work/a")
    described_class.new(dir).release(described_class::Claim.new("someone-else", nil))
    expect { described_class.new(dir).claim("work/b") }.to raise_error(described_class::Busy, %r{work/a})

    described_class.new(dir).release(first)
    expect { described_class.new(dir).claim("work/b") }.not_to raise_error
  end

  it "treats a claim past the stale window as abandoned" do
    past = -> { Time.now - (31 * 60) }
    described_class.new(dir, clock: past).claim("work/crashed")

    expect(described_class.new(dir).claim("work/b").superseded).to include("work/crashed")
  end
end

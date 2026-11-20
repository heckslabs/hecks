require "json"
require "hecks/fuzzing"
require "hecks/fuzzing/differential"
require_relative "../support/rust_conformance_helpers"
require_relative "../support/generated_rust"

# The gate of ADR 0188 step 9, slice 4: a known seeded divergence (a chess kernel that drops a
# sequence's last step) shrinks through `Differential::ShrinkSessions`, one warm `--serve` and a
# session per candidate, to the same steps as through a kernel run per candidate, in no more
# candidates. Each prints its time per candidate. Needs a real `cargo build` (`:io`).
RSpec.describe "Shrinking in kernel sessions (native binary)", :io do
  include_context "with the generated Rust tree"

  include RustConformanceHelpers

  SESSIONS = Hecks::Fuzzing::Differential::ShrinkSessions

  let(:domain) { File.join(InMemoryDomain::ROOT, "examples/chess") }
  let(:corpus) { JSON.parse(File.read(File.join(InMemoryDomain::ROOT, "spec/corpus/chess.json"))).fetch("steps") }
  let(:differ) do
    Class.new do
      include RustConformanceHelpers

      def structural_skips = @structural_skips ||= Set.new
    end.new
  end
  let(:binary) { build_rust_for("chess", File.join(InMemoryDomain::ROOT, "rust")) || skip("no chess feature") }

  # An engine that drops the last step of every sequence, so it must disagree with Ruby.
  def short(engine)
    Class.new(SimpleDelegator) { def call(domain, steps, **) = __getobj__.call(domain, steps[0...-1], **) }.new(engine)
  end

  def sessions
    @sessions ||= SESSIONS.new(short(Hecks::Fuzzing::Differential::ServeEngine.new(binary, batch: SESSIONS::NO_BATCH)),
                               differ: differ, domain_path: domain)
  end

  after { @sessions&.close }

  def today(steps)
    engine = short(Hecks::Fuzzing::Engine::Kernel.new(binary))
    Hecks::Fuzzing::Differential.diff(differ, domain, steps, engine, modes: [:differential]).fetch(:differential)
  end

  def signature(divergences) = Hecks::Fuzzing::Shrinker.signature(divergences)

  # Shrinks `corpus` against the original signature with `judge`, and prints the time per candidate.
  def shrink(label, original)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = Hecks::Fuzzing::Shrinker.call(corpus) { |candidate| Hecks::Fuzzing::Shrinker.reproduces?(original, yield(candidate)) }
    each = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / result.attempts
    RSpec.configuration.reporter.message("#{label}: #{result.attempts} candidates, #{(each * 1000).round(1)} ms each")
    result
  end

  # The seeded finding shrunk both ways: a kernel run per candidate, then a session per candidate.
  def both_ways
    original = signature(today(corpus))
    [SESSIONS.servable?(original),
     shrink("a kernel run per candidate", original) { |candidate| today(candidate) },
     shrink("a session per candidate", original) { |candidate| sessions.divergences(candidate) }]
  end

  it "shrinks the seeded divergence to the same steps in no more candidates", :aggregate_failures do
    servable, processes, served = both_ways
    expect([servable, served.steps]).to eq([true, processes.steps])
    expect(served.attempts).to be <= processes.attempts
  end

  # Candidates that end in a creating verb (an `instances` divergence), a move, and a dry run.
  def candidates
    dry_run = corpus[7].merge("dry_run" => corpus[7]["verb"]).except("verb")
    [corpus.first(1), corpus.first(6), corpus.first(8) + [dry_run]]
  end

  it "gives each candidate the served part of the signature a kernel run gives it" do
    served_part = ->(steps) { signature(today(steps)).select { |key| SESSIONS.servable?(Set[key]) }.to_set }
    expect(candidates.map { |steps| signature(sessions.divergences(steps)) }).to eq(candidates.map(&served_part))
  end
end

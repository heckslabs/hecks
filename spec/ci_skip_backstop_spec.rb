require "spec_helper"
require "yaml"

# Proves spec/support/ci_skip_backstop.rb's tables are live, not prose:
# an `ALLOWED` entry's destination job exists and runs the call site's spec
# file; every entry (`ALLOWED` or `UNROUTED_BUGS`) still matches a real `skip`
# call site, so a fixed bug or a deleted skip forces its entry out.
RSpec.describe CiSkipBackstop do
  WORKFLOWS = File.join(InMemoryDomain::ROOT, ".github/workflows")

  # Every job across every workflow file, by id => [file, job hash].
  def self.jobs
    Dir.glob(File.join(WORKFLOWS, "*.yml")).each_with_object({}) do |path, all|
      (YAML.load_file(path).fetch("jobs", {}) || {}).each { |id, job| (all[id] ||= []) << [File.basename(path), job] }
    end
  end

  def self.run_text(job) = Array(job["steps"]).filter_map { |step| step["run"] }.join("\n")

  def call_site_live?(entry)
    source = File.read(File.join(InMemoryDomain::ROOT, entry.call_site))
    source.include?(entry.literal) && source.match?(/\bskip\b/)
  end

  (described_class::ALLOWED + described_class::UNROUTED_BUGS).each do |entry|
    it "#{entry.call_site}: #{entry.literal[0, 50]}… is still a live skip call site its pattern matches", :aggregate_failures do
      expect(call_site_live?(entry)).to be(true),
                                        "#{entry.call_site} no longer holds a skip saying #{entry.literal.inspect} — " \
                                        "delete this entry"
      expect(entry.pattern).to match(entry.literal)
    end
  end

  described_class::ALLOWED.each do |entry|
    it "#{entry.call_site}: its destination #{entry.workflow} #{entry.job} exists and runs that spec file", :aggregate_failures do
      matches = self.class.jobs.fetch(entry.job, []).select { |file, _| file == entry.workflow }
      expect(matches).not_to be_empty, "no job #{entry.job} in .github/workflows/#{entry.workflow}"
      expect(self.class.run_text(matches.first.last)).to include(entry.call_site)
      expect(entry.reason.to_s.strip).not_to be_empty
    end
  end

  described_class::UNROUTED_BUGS.each do |entry|
    it "#{entry.call_site}: the bug names the real CI jobs it skips in, and why", :aggregate_failures do
      entry.jobs.each { |job| expect(self.class.jobs).to have_key(job) }
      expect(entry.why.to_s.strip).not_to be_empty
    end
  end

  # A stand-in for an RSpec example that ended `status`, described by the stem of its spec file.
  def fake_example(status, message, location, exception = nil)
    result = Struct.new(:status, :pending_message, :pending_exception).new(status, message, exception)
    Struct.new(:execution_result, :location, :full_description)
          .new(result, location, File.basename(location).delete_suffix("_spec.rb:1"))
  end

  it "fails a pending example whose reason no table accounts for, and passes one that is accounted for", :aggregate_failures do
    stray = fake_example(:pending, "x", "./spec/x_spec.rb:1")
    known = fake_example(:pending, described_class::UNROUTED_BUGS.first.literal, "./spec/y_spec.rb:1")
    passed = fake_example(:passed, nil, "./spec/z_spec.rb:1")

    expect(described_class.offenders([stray, known, passed]).size).to eq(1)
    expect(described_class.offenders([stray]).first).to include("./spec/x_spec.rb:1", "skipped: x")
  end

  it "passes a `pending` example that ran and failed as expected — a shrink-only pending table entry is a live check" do
    ran = fake_example(:pending, "BUG#32: not ported yet", "./spec/p_spec.rb:1", RuntimeError.new("expected"))

    expect(described_class.offenders([ran])).to be_empty
  end
end

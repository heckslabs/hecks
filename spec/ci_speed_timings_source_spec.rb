require "spec_helper"
require "json"
require "open3"
require "fileutils"
require "hecks/ci_speed/adapters/timings_source"

# The `TimingsSource` adapter reads the newest successful main run's timing artifacts through
# `gh`. `gh` is stubbed, so nothing is read from GitHub; whatever goes wrong, the adapter refuses
# and the bluebook's fallback policy plans by file size.
RSpec.describe Hecks::Adapters::TimingsSource do
  let(:source) { described_class.new }
  let(:ok) { instance_double(Process::Status, success?: true) }
  let(:failed) { instance_double(Process::Status, success?: false) }

  def fetch = source.fetch(name: { value: "rspec" }, timings_from: { value: "main" })

  # Answers `gh run list` with `runs`, and `gh run download` by writing `logs` into its --dir.
  def answer_gh(runs:, logs: {}, download: ok)
    allow(Open3).to receive(:capture3) do |*argv|
      next [runs.to_json, "", ok] if argv[2] == "list"

      write_logs(argv[argv.index("--dir") + 1], logs)
      ["", "boom", download]
    end
  end

  def write_logs(dir, logs) = logs.each { |name, text| File.write(File.join(dir, name), text) }

  it "merges the logs of the newest successful run" do
    answer_gh(runs: [{ databaseId: 7 }], logs: { "a.log" => "spec/a_spec.rb:1.5\n", "b.log" => "spec/b_spec.rb:2\n" })

    expect(fetch.dig(:timings, :value).lines.map(&:chomp)).to eq(%w[spec/a_spec.rb:1.5 spec/b_spec.rb:2.0])
  end

  it "refuses when no run succeeded on main" do
    answer_gh(runs: [])

    expect { fetch }.to raise_error(described_class::Unavailable, /no successful CI run/)
  end

  it "refuses when the artifacts cannot be downloaded" do
    answer_gh(runs: [{ databaseId: 7 }], download: failed)

    expect { fetch }.to raise_error(described_class::Unavailable, /could not download rspec-runtime-group-\*/)
  end

  it "refuses when the logs hold no timing" do
    answer_gh(runs: [{ databaseId: 7 }], logs: { "a.log" => "Run options: none\n" })

    expect { fetch }.to raise_error(described_class::Unavailable, /no timings found/)
  end

  it "refuses a directory that is not there" do
    expect { source.fetch(name: "rspec", timings_from: "tmp/no-such-dir") }
      .to raise_error(described_class::Unavailable, /not a directory/)
  end
end

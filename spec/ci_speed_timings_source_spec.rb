require "spec_helper"
require "json"
require "open3"
require "fileutils"
require "hecks/ci_speed/adapters/timings_source"

# The `TimingsSource` adapter reads the timing artifacts of the newest recent successful run that
# kept them, through `gh`. `gh` is stubbed, so nothing is read from GitHub; whatever goes wrong, the
# adapter refuses and the bluebook's fallback policy plans by file size.
RSpec.describe Hecks::Adapters::TimingsSource do
  let(:source) { described_class.new }
  let(:ok) { instance_double(Process::Status, success?: true) }
  let(:failed) { instance_double(Process::Status, success?: false) }

  def fetch = source.fetch(name: { value: "rspec" }, timings_from: { value: "main" })

  # Answers `gh run list` with `runs`, and `gh run download <id>` by writing `logs[id]` into its
  # --dir; a run with no entry in `logs` has no artifacts and the download fails.
  def answer_gh(runs:, logs: {})
    allow(Open3).to receive(:capture3) do |*argv|
      next [runs.to_json, "", ok] if argv[2] == "list"

      files = logs[argv[3].to_i]
      write_logs(argv[argv.index("--dir") + 1], files) if files
      ["", files ? "" : "no artifact matches any of the names or patterns provided", files ? ok : failed]
    end
  end

  def write_logs(dir, logs) = logs.each { |name, text| File.write(File.join(dir, name), text) }

  it "merges the logs of the newest successful run" do
    answer_gh(runs: [{ databaseId: 7 }], logs: { 7 => { "a.log" => "spec/a_spec.rb:1.5\n", "b.log" => "spec/b_spec.rb:2\n" } })

    expect(fetch.dig(:timings, :value).lines.map(&:chomp)).to eq(%w[spec/a_spec.rb:1.5 spec/b_spec.rb:2.0])
  end

  it "skips a run that kept no artifacts and reads the next one" do
    answer_gh(runs: [{ databaseId: 9 }, { databaseId: 7 }], logs: { 7 => { "a.log" => "spec/a_spec.rb:3\n" } })

    expect(fetch.dig(:timings, :value)).to eq("spec/a_spec.rb:3.0")
  end

  it "refuses when no run succeeded" do
    answer_gh(runs: [])

    expect { fetch }.to raise_error(described_class::Unavailable, /no successful CI run/)
  end

  it "refuses when no recent run kept the artifacts" do
    answer_gh(runs: [{ databaseId: 7 }, { databaseId: 9 }])

    expect { fetch }.to raise_error(described_class::Unavailable, /could not download rspec-runtime-group-\*/)
  end

  it "refuses at once on a gh failure that is not a missing artifact" do
    allow(Open3).to receive(:capture3) do |*argv|
      argv[2] == "list" ? [[{ databaseId: 7 }].to_json, "", ok] : ["", "HTTP 403", failed]
    end

    expect { fetch }.to raise_error(described_class::Unavailable, /run 7: HTTP 403/)
  end

  it "refuses when the logs hold no timing" do
    answer_gh(runs: [{ databaseId: 7 }], logs: { 7 => { "a.log" => "Run options: none\n" } })

    expect { fetch }.to raise_error(described_class::Unavailable, /no timings found/)
  end

  it "refuses a directory that is not there" do
    expect { source.fetch(name: "rspec", timings_from: "tmp/no-such-dir") }
      .to raise_error(described_class::Unavailable, /not a directory/)
  end
end

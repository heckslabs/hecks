# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/signalbox/adapters/looking"

# The disk the beat's look reads: the newest daily report of disk writes, as macOS words it, and the
# disk's free space. The look hands back steps and sizes as they stand and reckons no megabytes.
RSpec.describe Hecks::Adapters::Looking::Disk do
  let(:report) do
    <<~DIAG
      End time:         2026-11-20 23:59:13.000 -0700
      Steps:            83019 (10.49 MB/step)

      Powerstats for:   ruby
      UUID:             71
      Num samples:      39963

      Powerstats for:   git
      Num samples:      14789
    DIAG
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      File.write(File.join(dir, "disk writes_2026-11-21-003705_host.diag"), report)
      example.run
    end
  end

  it "reads the day, the size of a step and the steps of each process the report names" do
    expect(described_class.new(reports: @dir).facts).to include(
      writes_day: "2026-11-20", step_hundredths: 1049, ruby_steps: 39_963, git_steps: 14_789, rustc_steps: 0
    )
  end

  it "reads the disk's size and free space in megabytes" do
    expect(described_class.new(reports: @dir).facts).to include(disk_total: be > 0, disk_free: be > 0)
  end

  it "answers no day and no steps when no report is kept" do
    expect(described_class.new(reports: File.join(@dir, "none")).facts).to include(writes_day: "none", ruby_steps: 0)
  end
end

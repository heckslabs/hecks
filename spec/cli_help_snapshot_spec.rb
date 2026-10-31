require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

# The launcher's help, pinned as a reviewed diff: bare `hecks`, `hecks --help`, and each
# module's listing. A layout change shows up as a failing example naming the first line that
# moved. Regenerate with SNAPSHOT=rewrite only after reading the diff.
RSpec.describe "exe/hecks help snapshots", :io do
  def golden_dir = File.expand_path("golden/cli", __dir__)
  def exe = File.expand_path("../exe/hecks", __dir__)

  def fixed_env
    { "HECKS_USAGE" => "off", "LC_ALL" => "C.UTF-8", "HECKS_ENVIRONMENT" => nil,
      "PGHOST" => "127.0.0.1", "PGPORT" => "1", "PGPASSWORD" => nil }
  end

  snapshots = {
    "hecks" => [],
    "hecks-help" => ["--help"],
    "module-build" => ["build"], "module-check" => ["check"], "module-delegate" => ["delegate"],
    "module-deliver" => ["deliver"], "module-evolve" => ["evolve"], "module-find" => ["find"],
    "module-migrate" => ["migrate"], "module-operate" => ["operate"], "module-release" => ["release"],
    "module-serve" => ["serve"], "module-start" => ["start"], "module-test" => ["test"]
  }

  def launcher_output(argv)
    Dir.mktmpdir do |cache|
      env = fixed_env.merge("HECKS_CACHE_DIR" => cache)
      out, _err, _status = Open3.capture3(env, RbConfig.ruby, exe, *argv)
      out
    end
  end

  def golden_path(name) = File.join(golden_dir, "#{name}.txt")

  def record(name, actual)
    FileUtils.mkdir_p(golden_dir)
    File.write(golden_path(name), actual)
  end

  def first_difference(expected, actual)
    e = expected.lines
    a = actual.lines
    line = (0...[e.size, a.size].max).find { |i| e[i] != a[i] }
    return nil unless line

    "line #{line + 1}: expected #{e[line].inspect}, got #{a[line].inspect}"
  end

  snapshots.each do |name, argv|
    it "matches the #{name} snapshot" do
      actual = launcher_output(argv)
      record(name, actual) if ENV["SNAPSHOT"] == "rewrite"
      expect(first_difference(File.read(golden_path(name)), actual)).to be_nil
    end
  end

  it "names the first line that moved" do
    expected = File.read(golden_path("module-deliver"))
    changed = expected.sub("deliver — ", "delivers — ")
    expect(first_difference(expected, changed)).to include("line 1:")
  end

  it "reports a line added at the end" do
    expected = File.read(golden_path("module-deliver"))
    expect(first_difference(expected, "#{expected}extra\n")).to include("extra")
  end
end

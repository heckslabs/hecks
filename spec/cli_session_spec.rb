require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"

# A first session on a clean machine, through the real launcher as a subprocess (ADR 0163, plan
# step 39): `hecks tour` in an empty directory, then one command against the domain it wrote. It
# needs no network, no database and no git remote, and it removes its directory when done.
RSpec.describe "exe/hecks first session", :io do
  def exe = File.expand_path("../exe/hecks", __dir__)

  def clean_env(cache)
    { "HECKS_USAGE" => "off", "HECKS_CACHE_DIR" => cache, "LC_ALL" => "C.UTF-8",
      "HECKS_ENVIRONMENT" => nil, "PGHOST" => "127.0.0.1", "PGPORT" => "1", "PGPASSWORD" => nil }
  end

  def session(*argv)
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |cache|
        out, err, status = Open3.capture3(clean_env(cache), RbConfig.ruby, exe, *argv, chdir: root)
        yield(out, err, status.exitstatus, root)
      end
    end
  end

  it "tour writes a sample domain and exits 0" do
    session("tour", "demo") do |_out, _err, code, root|
      expect([code, File.directory?(File.join(root, "demo"))]).to eq([0, true])
    end
  end

  it "tour prints the command's result on stdout, with progress on stderr only" do
    session("tour", "demo") do |out, err, _code, _root|
      expect([out.include?("ExampleCreated"), err.include?("ExampleCreated")]).to eq([true, false])
    end
  end

  it "a second command against the tour's domain prints its event and exits 0" do
    session("tour", "demo") do |_out, _err, _code, root|
      out, _err, status = Open3.capture3(clean_env(root), RbConfig.ruby, exe, "Operation.run!",
                                         "subject.value=demo", "verb.value=Example.create!",
                                         "arguments.value=name=yourname", "--wait", chdir: root)
      expect([status.exitstatus, out.include?("ExampleCreated")]).to eq([0, true])
    end
  end

  it "a second tour in the same directory refuses with exit 1" do
    session("tour", "demo") do |_out, _err, _code, root|
      _out, _err, status = Open3.capture3(clean_env(root), RbConfig.ruby, exe, "tour", "demo", chdir: root)
      expect(status.exitstatus).to eq(1)
    end
  end

  it "an unknown command exits 2 through the real launcher" do
    session("no_such_command") do |_out, _err, code, _root|
      expect(code).to eq(2)
    end
  end
end

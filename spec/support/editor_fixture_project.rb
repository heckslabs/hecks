require "tmpdir"
require "fileutils"
require "json"
require "hecks/tools"
require "hecks/tools/site_routes"

# The helpers every editor-projection spec shares: project a neutral fixture site into the editor's
# files, read its schema back, compare the files that depend on the project with committed goldens
# (rewritten with `GOLDEN=rewrite`), and project a copy of the site with some of its text changed.
#
# A spec supplies `project` (a directory under spec/fixtures/site) and `golden_files`.
RSpec.shared_context "with an editor fixture project" do
  let(:golden) { File.join(project, "expected/editor") }

  # The editor's files for a project directory, keyed by their path inside the editor.
  def files_of(dir = project)
    all = Hecks::Tools::SiteRoutes.projection(dir, out: "/work/out", editor: "/work/editor")
    all.select { |path, _| path.start_with?("/work/editor/") }.transform_keys { |path| path.delete_prefix("/work/editor/") }
  end

  def editor_files = files_of(project)

  def neutral(text) = text.gsub("^#{Hecks::VERSION}", "^<version>")

  def schema(dir = project) = JSON.parse(files_of(dir).fetch("src/schema.ts")[/SCHEMA: Schema = (\{.*\});\n/m, 1])

  # The project with some text of one of its files changed (`from`, `to`, and more pairs of the same).
  def changed(file, *edits)
    Dir.mktmpdir("cms_editor") do |dir|
      FileUtils.cp_r(File.join(project, "."), dir)
      path = File.join(dir, file)
      edits.each_slice(2) do |from, to|
        raise "#{file} has no #{from.inspect}" unless File.read(path).include?(from)

        File.write(path, File.read(path).gsub(from, to))
      end
      yield dir
    end
  end

  def rewrite_goldens
    FileUtils.rm_rf(golden)
    golden_files.each do |name|
      FileUtils.mkdir_p(File.dirname(File.join(golden, name)))
      File.write(File.join(golden, name), neutral(editor_files.fetch(name)))
    end
  end
end

# The projection of the fixture project equals its committed goldens.
RSpec.shared_examples "an editor projection with committed goldens" do
  it "equals the committed goldens for the files that depend on the project", :aggregate_failures do
    rewrite_goldens if ENV["GOLDEN"] == "rewrite"

    golden_files.each do |name|
      expect(neutral(editor_files.fetch(name))).to eq(File.read(File.join(golden, name))), "#{name} has drifted from its golden"
    end
  end
end

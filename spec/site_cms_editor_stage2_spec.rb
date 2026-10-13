require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "hecks/tools"
require "hecks/tools/site_routes"

# What the editor derives for a working desk's parts, from declarations: the scheduled-action
# aggregate of a package that names neither its kinds nor its actions (the route rows say),
# what a due action does to a record (`EditorRun`), a moment entered on the clock of a zone, and the
# files of the runner, history, library, people, sign-in page and preview. The neutral project in
# spec/fixtures/site/editor_stage2 holds the files that depend on the project as goldens, rewritten
# with `GOLDEN=rewrite`.
RSpec.describe "the editor's working-desk parts, derived from the chapters" do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor_stage2") }
  let(:golden)  { File.join(project, "expected/editor") }
  let(:route)   { "bluebook/newsroom_site.bluebook" }
  let(:picture) { 'member aggregate: "Post", attribute: "photo", kind: "image", picks: "media"' }

  def golden_files = %w[package.json src/config.ts src/schema.ts]

  def files_of(dir = project)
    all = Hecks::Tools::SiteRoutes.projection(dir, out: "/work/out", editor: "/work/editor")
    all.select { |path, _| path.start_with?("/work/editor/") }.transform_keys { |path| path.delete_prefix("/work/editor/") }
  end

  def neutral(text) = text.gsub("^#{Hecks::VERSION}", "^<version>")

  def schema(dir = project) = JSON.parse(files_of(dir).fetch("src/schema.ts")[/SCHEMA: Schema = (\{.*\});\n/m, 1])

  # One attribute of one aggregate, as the editor reads it.
  def attribute(agg, name, dir = project)
    schema(dir)["aggregates"].find { |one| one["name"] == agg }["attributes"].find { |attr| attr["name"] == name }
  end

  # The project with some text of one of its files changed (`from`, `to`, and more such pairs).
  def changed(file, *edits)
    Dir.mktmpdir("cms_editor_stage2") do |dir|
      FileUtils.cp_r(File.join(project, "."), dir)
      path = File.join(dir, file)
      edits.each_slice(2) do |from, to|
        raise "#{file} has no #{from.inspect}" unless File.read(path).include?(from)

        File.write(path, File.read(path).gsub(from, to))
      end
      yield dir
    end
  end

  # The package's scheduled action as a package that does not say which records or actions: no key
  # pattern, no closed set. The route chapter's rows say the rest.
  def unsaid(&)
    plain = "attribute :value, String"
    changed("domain/bluebook/schedule.bluebook", "#{plain}, pattern: '^(post|page):[a-z0-9-]+$'", plain,
            "#{plain}, one_of: [\"publish\", \"withdraw\"]", plain, &)
  end

  # The route chapter with more `EditorField` rows, and the fields they use.
  def with_rows(dir, *lines)
    path = File.join(dir, route)
    fields = "      attribute :picks,     String\n"
    text = File.read(path).sub(fields, "#{fields}      attribute :keys,      String\n      attribute :options,   String\n")
    File.write(path, text.sub("      #{picture}", "#{lines.map { |line| "      member #{line}\n" }.join}      #{picture}"))
  end

  describe "the projection" do
    it "equals the committed goldens for the files that depend on the project", :aggregate_failures do
      rewrite if ENV["GOLDEN"] == "rewrite"

      golden_files.each do |name|
        expect(neutral(files_of.fetch(name))).to eq(File.read(File.join(golden, name))), "#{name} has drifted from its golden"
      end
    end

    def rewrite
      FileUtils.rm_rf(golden)
      golden_files.each do |name|
        FileUtils.mkdir_p(File.dirname(File.join(golden, name)))
        File.write(File.join(golden, name), neutral(files_of.fetch(name)))
      end
    end

    it "generates the files of the parts" do
      parts = %w[runner history library people ui/history ui/library ui/people ui/login ui/approximate ui/help]
      expect(files_of.keys).to include(*parts.map { |name| "src/#{name}.ts" })
    end
  end

  describe "the scheduled-action aggregate" do
    it "names the commands the runner settles an action with", :aggregate_failures do
      expect(schema["scheduling"]).to include("complete" => "Complete", "fail" => "Fail", "reason" => "reason")
    end

    it "says what a due action does to a record" do
      runs = [{ "aggregate" => "Post", "action" => "publish", "commands" => ["Publish"] },
              { "aggregate" => "Post", "action" => "withdraw", "commands" => ["Withdraw"] }]
      expect(schema["scheduling"]["runs"]).to eq(runs)
    end

    it "is not found when the package names neither its kinds nor its actions and no row does" do
      unsaid { |dir| expect(schema(dir)).not_to have_key("scheduling") }
    end

    it "reads the kinds of its subject from the route chapter's rows" do
      unsaid do |dir|
        with_rows(dir, 'aggregate: "ScheduledAction", attribute: "subject", keys: "post,page"',
                  'aggregate: "ScheduledAction", attribute: "action", options: "publish,withdraw"')
        expect(attribute("ScheduledAction", "subject", dir)["picker"]["kinds"].map { |kind| kind["kind"] }).to eq(%w[post page])
      end
    end

    it "reads the words of its actions from the route chapter's rows" do
      unsaid do |dir|
        with_rows(dir, 'aggregate: "ScheduledAction", attribute: "action", options: "publish=Put on the site,withdraw=Take off"')
        expect(attribute("ScheduledAction", "action", dir)["optionLabels"]).to include("publish" => "Put on the site")
      end
    end

    it "refuses a run row that names a command the aggregate does not have" do
      changed(route, 'action: "withdraw", command: "Withdraw"', 'action: "withdraw", command: "Retire"') do |dir|
        expect { files_of(dir) }.to raise_error(SystemExit, /Post has no command "Retire"/)
      end
    end

    it "refuses a key kind that is not a lower-case word" do
      unsaid do |dir|
        with_rows(dir, 'aggregate: "ScheduledAction", attribute: "subject", keys: "Post"')
        expect { files_of(dir) }.to raise_error(SystemExit, /not a kind word/)
      end
    end
  end

  describe "the Editor row" do
    it "refuses a sign-in address that is not a path on the site's own origin" do
      changed(route, 'sign_in: "/auth/google"', 'sign_in: "https://accounts.example.com/"') do |dir|
        expect { files_of(dir) }.to raise_error(SystemExit, /sign_in .* must be a path on the site's own origin/)
      end
    end

    it "refuses a landing path that is not a path on the site's own origin" do
      changed(route, 'landing: "/admin.html"', 'landing: "//elsewhere.test/x"') do |dir|
        expect { files_of(dir) }.to raise_error(SystemExit, /landing .* must be a path/)
      end
    end

    it "holds the zone, the roles that administer, the sign-in and the landing in the config", :aggregate_failures do
      config = files_of.fetch("src/config.ts")
      expect(config).to include('zone: "-07:00" as string', 'adminRoles: ["Admin", "Owner"] as readonly string[]')
      expect(config).to include('signIn: "/auth/google" as string | null', 'landing: "/admin.html" as string | null')
    end
  end

  describe "a moment entered on a zone's clock" do
    let(:zoned) do
      fields = "      attribute :picks,     String\n"
      row = 'member aggregate: "ScheduledAction", attribute: "due_at", kind: "datetime", zone: "-07:00"'
      [fields, "#{fields}      attribute :zone,      String\n", "      #{picture}", "      #{picture}\n      #{row}"]
    end

    it "carries the zone on an integer moment a row names one for" do
      changed(route, *zoned) { |dir| expect(attribute("ScheduledAction", "due_at", dir)).to include("wall" => "-07:00") }
    end
  end
end

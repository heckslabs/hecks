require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "hecks/tools"
require "hecks/tools/site_routes"

# The editor's look: the theme the Editor row's accent makes, the brand and logo it names, and the
# rules that decide which commands ask first and what colour a lifecycle state's badge has. The
# contrast checks read the generated stylesheet's own colours, not the generator's, and hold every
# text and fill pair to the accessibility standard's contrast ratios in both themes, whatever the
# accent.
RSpec.describe "the generated editor's theme" do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor") }

  # The editor's files for the Editor row with `edit` added to its source (the fixture's when nil).
  def generated(edit = nil)
    Dir.mktmpdir("cms_editor_theme") do |dir|
      FileUtils.cp_r(File.join(project, "."), dir)
      file = File.join(dir, "bluebook/press_site.bluebook")
      File.write(file, File.read(file).sub('title: "Press editor"', "title: \"Press editor\"#{edit}")) if edit
      files = Hecks::Tools::SiteRoutes.projection(dir, out: "/work/out", editor: "/work/editor")
      files.transform_keys { |path| path.delete_prefix("/work/editor/") }
    end
  end

  def refused(edit)
    generated(edit)
  rescue SystemExit => e
    e.message
  end

  # Each theme's properties, from the `@plugin "daisyui/theme"` block that declares it.
  def themes(css)
    %w[editor-light editor-dark].to_h do |name|
      block = css[/name: "#{name}";(.*?)\n\}/m, 1]
      [name, block.scan(/(--[\w-]+): (#[0-9a-f]{6});/).to_h]
    end
  end

  def luminance(hex)
    red, green, blue = hex.delete_prefix("#").scan(/../).map { |pair| linear(pair.hex / 255.0) }
    (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
  end

  def linear(channel) = channel <= 0.03928 ? channel / 12.92 : ((channel + 0.055) / 1.055)**2.4

  def ratio(one, other)
    high, low = [luminance(one), luminance(other)].minmax.reverse
    (high + 0.05) / (low + 0.05)
  end

  TONE_FILLS = { "--color-success" => "--ed-ok-bg", "--color-warning" => "--ed-warn-bg",
"--color-error" => "--ed-danger-bg" }.freeze
  FILLS = %w[primary secondary accent info success warning error neutral].freeze

  # The text pairs and fills a theme must hold, as [foreground, background, least ratio].
  def pairs
    text = %w[--color-base-content --ed-muted --color-primary].product(%w[--color-base-100 --color-base-200])
    fills = FILLS.map { |name| ["--color-#{name}-content", "--color-#{name}"] }
    [*text, *fills, *TONE_FILLS.to_a, %w[--color-primary --ed-soft]].map do |fg, bg|
      [fg, bg, 4.5]
    end + [["--ed-edge", "--color-base-100", 3.0]]
  end

  def failing(css)
    themes(css).flat_map do |name, theme|
      pairs.filter_map do |fg, bg, least|
        found = ratio(theme.fetch(fg), theme.fetch(bg))
        "#{name}: #{fg} on #{bg} is #{found.round(2)}, needs #{least}" if found < least
      end
    end
  end

  describe "the palette" do
    it "reaches WCAG AA for every text and fill pair, in both themes, with the default accent" do
      expect(failing(generated.fetch("src/browser/app.css"))).to be_empty
    end

    it "reads the stylesheet's colours, so a pair that does not read is found", :aggregate_failures do
      css = generated.fetch("src/browser/app.css").sub("--color-primary: #1f7a6d;", "--color-primary: #ffee00;")

      expect(themes(css).fetch("editor-light").size).to be > 25
      expect(failing(css)).to include(a_string_matching(/editor-light: --color-primary on --color-base-100/))
    end

    it "holds for accents that would fail unmoved: a light yellow, a pure red, a dark navy, a pale green", :aggregate_failures do
      %w[#ffee00 #ff0000 #0b1f4d #b8f5c8 #777777].each do |accent|
        css = generated(", accent: \"#{accent}\"").fetch("src/browser/app.css")

        expect(failing(css)).to be_empty, "accent #{accent}: #{failing(css).first}"
      end
    end

    it "gives the default theme the neutrals and the accent it is documented with", :aggregate_failures do
      light, dark = themes(generated.fetch("src/browser/app.css")).values_at("editor-light", "editor-dark")

      expect(light.values_at("--color-base-200", "--color-base-100", "--color-base-content")).to eq(%w[#f4f6f8 #ffffff #1a222c])
      expect(dark.values_at("--color-base-200", "--color-base-100", "--color-base-content")).to eq(%w[#11161b #181f26 #e7ebef])
      expect(light["--color-primary"]).to eq("#1f7a6d")
    end

    it "retints the neutrals with the accent's hue, so the accent changes the whole theme", :aggregate_failures do
      light = themes(generated(", accent: \"#c0392b\"").fetch("src/browser/app.css")).fetch("editor-light")

      expect(light["--color-base-200"]).not_to eq("#f4f6f8")
      expect(light["--color-base-100"]).to eq("#ffffff")
    end

    it "makes the same stylesheet on every run" do
      once = generated(", accent: \"#336699\"")

      expect(generated(", accent: \"#336699\"")).to eq(once)
    end

    it "fills the primary button with ink and keeps the accent for focus and links", :aggregate_failures do
      css = generated.fetch("src/browser/app.css")
      light = themes(css).fetch("editor-light")

      expect(light["--color-neutral"]).to eq(light["--color-base-content"])
      expect(light["--color-primary"]).not_to eq(light["--color-neutral"])
    end
  end

  describe "the Editor row's look" do
    it "is refused when the accent is not a six-digit hex colour", :aggregate_failures do
      ["red", "#12", "#12345g", "1f7a6d", "#1f7a6d00"].each do |accent|
        expect(refused(", accent: \"#{accent}\"")).to include("accent #{accent.inspect} must be a six-digit hex colour")
      end
    end

    it "is refused when the logo is not a relative path to a picture file", :aggregate_failures do
      ["/etc/logo.png", "../logo.png", "logo.exe", "a/.hidden/logo.png", "logo", "a//logo.png"].each do |logo|
        expect(refused(", logo: \"#{logo}\"")).to include("logo #{logo.inspect} must be a relative path")
      end
    end

    it "accepts a logo path, and the server reads it from its own directory", :aggregate_failures do
      config = generated(", logo: \"brand/logo.svg\"").fetch("src/config.ts")

      expect(config).to include('logo: "brand/logo.svg"')
      expect(generated.fetch("src/config.ts")).to include('logo: ""')
    end

    it "shows the domain's name as the brand unless the row names one", :aggregate_failures do
      expect(generated.fetch("src/config.ts")).to include('brand: "Press"')
      expect(generated(", brand: \"The Harbour Post\"").fetch("src/config.ts")).to include('brand: "The Harbour Post"')
    end

    it "is refused when the brand is more than one line or too long", :aggregate_failures do
      expect(refused(", brand: \"#{"x" * 61}\"")).to include("brand must be one line of at most 60 characters")
      expect(refused(", brand: \"a\\nb\"")).to include("brand must be one line")
    end
  end

  describe "which commands ask first" do
    let(:article) { JSON.parse(generated.fetch("src/schema.ts")[/SCHEMA: Schema = (\{.*\});\n/m, 1])["aggregates"].first }

    def destructive = article["commands"].to_h { |command| [command["name"], command["destructive"]] }

    it "confirms a command whose first word is one that ends or undoes something", :aggregate_failures do
      expect(destructive["DiscardDraft"]).to be(true)
      expect(destructive.except("DiscardDraft").values).to all(be(false))
    end

    it "confirms a lifecycle move into a state named for one of those words, however the move is named", :aggregate_failures do
      lifecycle = { "default" => "open", "transitions" => [{ "verb" => "Close", "from" => ["open"], "to" => "cancelled" }] }
      destructive = Hecks::Projections::Site::CmsEditor::Destructive

      expect(destructive.command?("Close", lifecycle)).to be(true)
      expect(destructive.command?("Reopen", lifecycle)).to be(false)
      expect(destructive.command?("RemoveItem", nil)).to be(true)
    end

    it "does not confirm a move that can be undone: an archive with a restore" do
      expect(destructive["Archive"]).to be(false)
    end

    it "gives each lifecycle state a tone: the starting state neutral, then ok and info in turn", :aggregate_failures do
      expect(article["lifecycle"]["tones"]).to eq("draft" => "neutral", "published" => "ok", "archived" => "info")
    end

    it "gives a state named for a destructive word the danger tone" do
      move = { "from" => ["open"], "to" => "withdrawn", "verb" => "Withdraw" }
      tones = Hecks::Projections::Site::CmsEditor::Destructive.tones("default" => "open", "transitions" => [move])

      expect(tones).to eq("open" => "neutral", "withdrawn" => "danger")
    end
  end

  describe "colour arithmetic" do
    let(:color) { Hecks::Projections::Site::CmsEditor::Color }

    it "measures contrast as WCAG does", :aggregate_failures do
      expect(color.contrast("#000000", "#ffffff")).to be_within(0.01).of(21.0)
      expect(color.contrast("#777777", "#777777")).to eq(1.0)
    end

    it "moves a colour until it reads, and leaves one that already reads", :aggregate_failures do
      expect(color.contrast(color.reach("#ffee00", ["#ffffff"], 4.5, :darker), "#ffffff")).to be >= 4.5
      expect(color.reach("#000000", ["#ffffff"], 4.5, :darker)).to eq("#000000")
    end

    it "goes between hex and hue, saturation and lightness without drifting" do
      expect(color.from_hsl(*color.hsl("#1f7a6d"))).to eq("#1f7a6d")
    end
  end
end

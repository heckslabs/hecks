require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "hecks/tools"
require "hecks/tools/site_routes"

# What a real client's adoption of the Site chapter needed beyond the studio sample: a project run
# from outside a checkout with its template and output anywhere, a site with no load balancer, a page
# that is off but keeps its navigation slots, links to an endpoint and to a fragment, a heading in
# the mobile menu, edge verbs apart from a route's own, a SEO title, a public page beneath the admin
# prefix, `*` matching as a CDN reads it, and a module Node loads under a commonjs package.
# spec/fixtures/site/gallery is the neutral sample project that uses them; its goldens sit in
# spec/fixtures/site/gallery/expected (`GOLDEN=rewrite` regenerates them, to be read in the diff).
RSpec.describe "the Site chapter beyond the studio sample" do
  let(:tool)       { Hecks::Tools::SiteRoutes }
  let(:gallery)    { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/gallery") }
  let(:studio)     { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/studio") }
  let(:expected)   { File.join(gallery, "expected") }
  let(:work)       { Dir.mktmpdir("site_gaps") }
  let(:table_class) { Hecks::Projections::Site::Table }

  after { FileUtils.rm_rf(work) }

  def projected(project = gallery, **options) = tool.projection(project, out: "/work/out", **options)

  def routes_ts(project = gallery) = projected(project).fetch("/work/out/routes.ts")

  # A copy of the gallery whose route chapter is changed by the block, given its text.
  def edited_gallery
    dir = File.join(work, "project")
    FileUtils.cp_r(gallery, dir)
    FileUtils.rm_rf(File.join(dir, "expected"))
    path = File.join(dir, "bluebook/gallery_site.bluebook")
    File.write(path, yield(File.read(path)))
    dir
  end

  def refusal(project, **options)
    message = nil
    expect { tool.projection(project, **options) }.to raise_error(SystemExit) { |error| message = error.message }
                                                  .and output.to_stderr
    message
  end

  def refused(rows, links: [])
    vocabulary = table_class.vocabulary(tool.registry_for(gallery))
    table_class.new(rows, vocabulary: vocabulary, links: links)
    nil
  rescue table_class::Invalid => e
    e.message
  end

  describe "the gallery projection" do
    it "equals the committed goldens, byte for byte" do
      files = projected
      if ENV["GOLDEN"] == "rewrite"
        FileUtils.mkdir_p(expected)
        File.write(File.join(expected, "routes.ts"), files.fetch("/work/out/routes.ts"))
        File.write(File.join(expected, "template.yaml"), files.fetch("/work/out/deploy/template.yaml"))
      end

      expect(files.fetch("/work/out/routes.ts")).to eq(File.read(File.join(expected, "routes.ts")))
      expect(files.fetch("/work/out/deploy/template.yaml")).to eq(File.read(File.join(expected, "template.yaml")))
    end

    it "leaves the studio project, which uses none of this, exactly as the 3.1 projection wrote it apart from matchesPath" do
      text = routes_ts(studio)

      expect(text).not_to include("seoTitle", "fragment", "heading:", "switch: \"podcast\", on:")
    end
  end

  describe "an edge with no load balancer" do
    it "projects the behaviours alone, and no listener_rules region is needed in the template" do
      files = projected

      expect(files.fetch("/work/out/deploy/template.yaml")).to include("PathPattern: \"/cms/*\"")
      expect(files.fetch("/work/out/deploy/template.yaml")).not_to include("ListenerRule", "listener_rules")
    end

    it "refuses a template that still holds a listener_rules region" do
      dir = edited_gallery { |text| text }
      path = File.join(dir, "deploy/template.yaml")
      File.write(path,
                 "#{File.read(path)}  # BEGIN GENERATED site_cdn listener_rules\n  # END GENERATED site_cdn listener_rules\n")

      expect(refusal(dir)).to include("has a BEGIN/END GENERATED site_cdn listener_rules region", "alb: false")
    end

    it "refuses a rule row and a route that names a rule, which describe a load balancer the edge lacks" do
      rule = refusal(edited_gallery do |text|
        text.sub('    command "Name"', "    value_object \"EdgeRule\" do\n      attribute :rule, String\n      " \
                                       "member rule: \"R\", priority: 1, origin: \"cms\"\n    end\n\n    command \"Name\"")
      end)
      named = refusal(edited_gallery { |text| text.sub('member path: "/cms/*",', 'member path: "/cms/*", alb_rule: "R",') })

      expect(rule).to include("EdgeRule rows describe a load balancer, and the Edge row says alb: false")
      expect(named).to include("/cms/* names alb_rule R, and the Edge row says alb: false")
    end

    it "still refuses a cms route whose origin no EdgeOrigin maps, even one the CDN skips" do
      unmapped = refusal(edited_gallery { |text| text.sub(/      member origin: "cms".*\n/, "") })
      skipped = refusal(edited_gallery do |text|
        text.sub(/      member origin: "cms".*\n/, "").sub(%r{member path: "/cms/\*",\s+kind},
                                                           'member path: "/cms/*", cdn: false, kind')
      end)

      expect(unmapped).to include("/cms/* has origin cms, which no EdgeOrigin maps")
      expect(skipped).to include("/cms/* is served from cms, which no EdgeOrigin maps, " \
                                 "and with alb: false nothing else reaches it")
    end

    it "keeps asking an edge with a load balancer for its rules" do
      expect(Hecks::Tools::SiteRoutes.projection(studio, out: "/work/out").fetch("/work/out/deploy/template.yaml"))
        .to include("ListenerRuleCms:")
    end

    it "takes only true or false for alb" do
      message = refusal(edited_gallery { |text| text.sub("alb: false", 'alb: "no"') })

      expect(message).to include('Edge row 1 has alb "no"; alb is true or false')
    end
  end

  describe "a page that is off" do
    it "keeps its navigation slots, each entry carrying the switch and on: false" do
      text = routes_ts

      expect(text).to include('{ path: "/shop", label: "Shop", switch: "shop", on: false }',
                              '{ heading: "More", path: "/shop", label: "Shop", switch: "shop", on: false }')
      expect(text).to include('off: { status: 404, paths: ["/shop"] }')
      expect(text).not_to match(/SITEMAP_PATHS = \[[^\]]*shop/)
    end

    it "gives a page that is on no switch or on key" do
      expect(routes_ts).to include('{ path: "/", label: "Home" }')
    end
  end

  describe "navigation to an endpoint, a fragment and under a heading" do
    it "lets an endpoint or a redirect sit in a menu, and refuses a route that does not answer GET" do
      expect(routes_ts).to include('{ path: "/ticket-file", label: "Download tickets" }',
                                   '{ path: "/press-kit", label: "Press kit" }')
      expect(refused([{ path: "/send", kind: "endpoint", methods: "POST", label: "Send", footer_column: "Studio" }]))
        .to include("/send sits in the navigation but answers POST; a link is a GET")
    end

    it "carries a fragment on the entry of a NavLink, beside the entry of the page itself" do
      expect(routes_ts).to include('{ path: "/about", label: "About" }',
                                   '{ path: "/about", label: "Opening hours", fragment: "opening-hours" }')
    end

    it "carries a heading on the mobile entry that opens a section" do
      expect(routes_ts).to include('{ heading: "Visit", path: "/exhibitions", label: "Exhibitions" }')
      expect(refused([{ path: "/a", label: "A", footer_column: "X", mobile_heading: "Menu" }]))
        .to include("/a has a mobile_heading but no mobile_order")
    end

    it "refuses a NavLink that points at no route, has no slot or label, or a fragment that is not an id" do
      rows = [{ path: "/a" }]
      message = refused(rows, links: [{ path: "/missing", label: "M", nav_order: 1 }, { path: "/a", label: "A" },
                                      { path: "/a", nav_order: 1 }, { path: "/a", label: "A", nav_order: 1, fragment: "#top" },
                                      { path: "/a", label: "A", nav_order: 1, colour: "red" }])

      expect(message).to include("NavLink /missing points at no route that answers GET",
                                 "NavLink /a sits in no navigation", "NavLink /a has no label",
                                 'NavLink /a has fragment "#top"', "NavLink /a has no field colour")
    end

    it "refuses a link to an admin page in a public menu, and one admin key used twice" do
      rows = [{ path: "/admin-a", auth: "admin", label: "A", admin_key: "a", admin_order: 1 }]
      links = [{ path: "/admin-a", label: "A2", footer_column: "X" }, { path: "/admin-a", label: "A3", admin_key: "a" }]

      expect(refused(rows, links: links)).to include("NavLink /admin-a is an admin page in the footer navigation",
                                                     "admin key a is used by 2 routes")
    end
  end

  describe "edge verbs apart from a route's own" do
    it "lets admin pages answer GET and ride the prefix that lets POST through, with no behaviour of their own" do
      template = projected.fetch("/work/out/deploy/template.yaml")

      expect(routes_ts).to include('path: "/admin-orders", kind: "page", render: "ssr", auth: "admin", methods: ["GET"]')
      expect(template).to include('PathPattern: "/admin*"')
      expect(template).not_to include('PathPattern: "/admin-orders"', 'PathPattern: "/admin-export"', 'PathPattern: "/api/ping"')
    end

    it "gives such a route a behaviour of its own, reading GET alone, when it names no edge verbs" do
      dir = edited_gallery do |text|
        text.sub('member path: "/admin-orders", render: "ssr", auth: "admin", edge_methods: "GET,POST",',
                 'member path: "/admin-orders", render: "ssr", auth: "admin",')
      end

      expect(refusal(dir)).to include("/admin-orders is shadowed by /admin*")
    end

    it "refuses edge verbs that leave out a verb the route answers, or are not verbs" do
      expect(refused([{ path: "/a", methods: "GET,POST", edge_methods: "GET" }]))
        .to include("/a has edge_methods GET, which leave out its methods POST")
      expect(refused([{ path: "/a", edge_methods: "GET,FETCH" }])).to include('/a has edge method "FETCH"')
    end
  end

  describe "a SEO title" do
    it "is written for a row that sets it, beside its seo id, and left out for one that does not" do
      text = routes_ts

      expect(text).to include('seo: "home", redirectTo: null, seoTitle: "Harbor Gallery | Contemporary art" }')
      expect(text).to include('path: "/about", kind: "page"')
      expect(text.lines.grep(%r{path: "/about"}).first).not_to include("seoTitle")
    end
  end

  describe "a public page beneath the admin prefix" do
    it "is the sign-in page: public, uncached, indexable false, riding /admin* when the edge allows its verbs" do
      template = projected.fetch("/work/out/deploy/template.yaml")

      expect(routes_ts).to include('path: "/admin-login", kind: "page", render: "ssr", auth: "public",',
                                   'methods: ["GET"], cache: "no_store"')
      expect(template).not_to include('PathPattern: "/admin-login"')
      expect(routes_ts).to match(/SITEMAP_PATHS = \[[^\]]*\]/)
      expect(routes_ts[/SITEMAP_PATHS = \[[^\]]*\]/]).not_to include("admin-login")
    end

    it "is refused when it does not name its cache class, since the prefix is not public" do
      dir = edited_gallery do |text|
        text.sub('member path: "/admin-login", render: "ssr", cache: "no_store",',
                 'member path: "/admin-login", render: "ssr",')
      end

      expect(refusal(dir)).to include("/admin-login is public but sits beneath /admin*, which is admin; name its cache class")
    end

    it "does not refuse a public page beneath a public prefix" do
      expect(refused([{ path: "/api/*", kind: "endpoint" }, { path: "/api/x", kind: "endpoint" }])).to be_nil
    end
  end

  describe "the tool, run on its own" do
    def run(*argv)
      out = StringIO.new
      err = StringIO.new
      $stdout = out
      $stderr = err
      [tool.main(argv), out.string, err.string]
    ensure
      $stdout = STDOUT
      $stderr = STDERR
    end

    it "writes routes to --out and rewrites a --template anywhere in place, apart from the project" do
      template = File.join(work, "infra/stack.yaml")
      FileUtils.mkdir_p(File.dirname(template))
      FileUtils.cp(File.join(gallery, "deploy/template.yaml"), template)

      status, out, = run(gallery, "--out=#{work}/web/generated", "--template=#{template}")

      expect(status).to eq(0)
      expect(out).to eq("wrote #{work}/web/generated/routes.ts\nwrote #{template}\n")
      expect(File.read(template)).to eq(File.read(File.join(expected, "template.yaml")))
      expect(File.read(File.join(work, "web/generated/routes.ts"))).to eq(File.read(File.join(expected, "routes.ts")))
      expect(run(gallery, "--out=#{work}/web/generated", "--template=#{template}", "--check").first).to eq(0)
    end

    it "uses the working directory as the project when none is named" do
      Dir.chdir(gallery) do
        status, out, = run("--out=#{work}/o", "--check")

        expect(status).to eq(1)
        expect(out).to eq("")
      end
    end

    it "names the module routes.mts under --extension=mts, with the same text" do
      files = projected(extension: "mts")

      expect(files.keys).to eq(["/work/out/routes.mts", "/work/out/deploy/template.yaml"])
      expect(files.fetch("/work/out/routes.mts")).to eq(File.read(File.join(expected, "routes.ts")))
    end

    it "refuses an unknown extension, a --template for a project with no edge, a missing template and an --out that is a file" do
      expect(refusal(gallery, extension: "cjs")).to include("--extension is one of ts, mts")
      expect(refusal(gallery, template: File.join(work, "nothing.yaml"))).to include("nothing.yaml does not exist")
      file = File.join(work, "a_file")
      File.write(file, "")
      expect(refusal(gallery, out: file)).to include("is a file")
      bare = edited_gallery { |text| text.sub(/    # The edge:.*?(?=\n    command "Name")/m, "") }
      expect(refusal(bare, template: file)).to include("the project declares no Edge rows")
    end

    it "lets the Edge row leave out its template when the tool is told which file" do
      dir = edited_gallery { |text| text.sub('member template: "deploy/template.yaml", alb: false', "member alb: false") }
      template = File.join(dir, "deploy/template.yaml")

      expect(refusal(dir)).to include("Edge has no template")
      expect(tool.projection(dir, template: template).keys).to include(template)
    end
  end

  describe "the generated module, run by node" do
    def node? = system("node", "--version", out: File::NULL, err: File::NULL)

    # The module is loaded as an .mts file inside a package whose "type" is "commonjs".
    def run_node(script)
      Dir.mktmpdir("routes_mts") do |dir|
        File.write(File.join(dir, "package.json"), '{ "type": "commonjs" }')
        File.write(File.join(dir, "routes.mts"), routes_ts)
        File.write(File.join(dir, "check.mjs"), "import * as site from './routes.mts';\n#{script}")
        out, err, status = Open3.capture3({ "NODE_NO_WARNINGS" => "1" }, "node", File.join(dir, "check.mjs"))
        [out, status, err]
      end
    end

    it "loads under a commonjs package and matches a trailing * as the CDN reads it" do
      skip "node is not installed" unless node?

      out, status, err = run_node(<<~JS)
        const m = site.matchesPath;
        console.log(JSON.stringify({
          prefixStar: [m("/admin*", "/admin"), m("/admin*", "/admin-orders"), m("/admin*", "/admin-orders.html"),
                       m("/admin*", "/admin/x/y"), m("/admin*", "/adm")],
          slashStar: [m("/cms/*", "/cms/x"), m("/cms/*", "/cms/a/b"), m("/cms/*", "/cms"), m("/cms/*", "/cmsx")],
          middle: [m("/a*z", "/abz"), m("/a*z", "/a/b/z"), m("/a*z", "/abq")],
          param: [m("/blog/:slug.html", "/blog/x"), m("/blog/:slug.html", "/blog/x/y")],
          dots: [m("/a.b*", "/a.bc"), m("/a.b*", "/axbc")],
          off: [site.pageIsOn("shop"), site.NAV_DESKTOP.flatMap((e) => e.items).filter((i) => !("switch" in i) || site.pageIsOn(i.switch)).length],
          search: [site.notForSearch("/admin-login"), site.notForSearch("/exhibitions")],
        }));
      JS

      expect(status.success?).to be(true), err
      expect(JSON.parse(out)).to eq(
        "prefixStar" => [true, true, true, true, false], "slashStar" => [true, true, false, false],
        "middle" => [true, true, false], "param" => [true, false], "dots" => [true, false],
        "off" => [false, 3], "search" => [true, false]
      )
    end
  end
end

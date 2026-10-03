require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/tools"
require "hecks/tools/site_routes"

# The edge of the Site chapter: CloudFront behaviours and listener rules projected from the route
# table into the marked regions of a template the project owns. spec/fixtures/site/studio is the
# neutral sample project; spec/fixtures/site/template.yaml is its template as the projection must
# leave it, byte for byte (`GOLDEN=rewrite` regenerates it, to be read in the diff).
RSpec.describe "the Site chapter's edge" do
  let(:tool)    { Hecks::Tools::SiteRoutes }
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/studio") }
  let(:golden)  { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/template.yaml") }
  let(:work)    { Dir.mktmpdir("site_edge") }

  after { FileUtils.rm_rf(work) }

  def projected(dir = project) = tool.projection(dir, out: "/work/out").fetch("/work/out/deploy/template.yaml")

  # A copy of the sample project whose route table is changed by `edit`, a block given the text.
  def edited_project
    dir = File.join(work, "project")
    FileUtils.cp_r(project, dir)
    path = File.join(dir, "bluebook/studio_site.bluebook")
    File.write(path, yield(File.read(path)))
    dir
  end

  describe "the projection" do
    it "equals the committed template, byte for byte" do
      File.write(golden, projected) if ENV["GOLDEN"] == "rewrite"

      expect(projected).to eq(File.read(golden)),
                           "the template for the sample project has drifted from spec/fixtures/site/template.yaml"
    end

    it "is the same text on every run, and leaves what is outside the regions alone" do
      source = File.read(File.join(project, "deploy/template.yaml"))

      first = tool.projection(project, out: "/work/out")
      second = tool.projection(project, out: "/work/out")

      expect(first).to eq(second)
      expect(projected.lines.first(14)).to eq(source.lines.first(14))
      expect(projected).not_to match(%r{Users|/tmp})
    end

    it "gives a page cached like the default no behaviour, and one cached differently its own" do
      behaviors = projected

      expect(behaviors).not_to include('PathPattern: "/about"', 'PathPattern: "/blog/*.html"', 'PathPattern: "/sitemap.xml"')
      expect(behaviors).to include('PathPattern: "/"', 'PathPattern: "/robots.txt"', 'PathPattern: "/inquiry-received"')
    end

    it "gives a signed page and a no_store page behaviours that are never cached, over https only" do
      block = projected[%r{PathPattern: "/pay/\*".*?(?=- PathPattern)}m]

      expect(block).to include("ViewerProtocolPolicy: https-only", "# Managed-CachingDisabled")
    end

    it "gives a page under a broader route of the same behaviour no behaviour of its own" do
      expect(projected).to include('PathPattern: "/admin*"')
      expect(projected).not_to include('PathPattern: "/admin-inbox"')
    end

    it "leaves a route that skips the CDN out of the behaviours and keeps it in the rule that carries it" do
      expect(projected).not_to include('PathPattern: "/internal/ping"')
      expect(projected).to include('"/internal/ping"')
    end

    it "sends the assets origin to its own origin id, with no origin request policy" do
      block = projected[%r{PathPattern: "/videos/\*".*?(?=- PathPattern)}m]

      expect(block).to include("TargetOriginId: AssetsOrigin", "AllowedMethods: [GET, HEAD]", "Compress: false")
      expect(block).not_to include("OriginRequestPolicyId", "ResponseHeadersPolicyId")
    end

    it "orders the behaviours as the table declares them, the specific before the general" do
      order = projected.scan(/PathPattern: "([^"]+)"/).flatten

      expect(order.index("/cms/_static/*")).to be < order.index("/cms/*")
      expect(order.index("/cms/media/*")).to be < order.index("/cms/*")
    end

    it "writes each listener rule by priority, the website's with no path condition" do
      rules = projected.scan(/^  (ListenerRule\w+):/).flatten
      website = projected[/  ListenerRuleWebsite:.*?(?=\n  # END)/m]

      expect(rules).to eq(%w[ListenerRuleCms ListenerRuleDomain ListenerRuleDomainAuth ListenerRuleWebsite])
      expect(website).not_to include("path-pattern")
      expect(website).to include("HttpHeaderName: X-Origin-Secret", "TargetGroupArn: !Ref WebsiteTargetGroup")
    end
  end

  describe "main" do
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

    it "rewrites the template in place, and a second run finds it current" do
      dir = File.join(work, "project")
      FileUtils.cp_r(project, dir)

      status, out, = run(dir)
      expect(status).to eq(0)
      expect(out).to include("wrote deploy/template.yaml")
      expect(File.read(File.join(dir, "deploy/template.yaml"))).to eq(File.read(golden))

      expect(run(dir, "--check").first).to eq(0)
    end

    it "with --check names a template whose region was edited by hand, and changes nothing" do
      dir = File.join(work, "project")
      FileUtils.cp_r(project, dir)
      run(dir)
      path = File.join(dir, "deploy/template.yaml")
      File.write(path, File.read(path).sub("Priority: 10", "Priority: 11"))

      status, _, err = run(dir, "--check")

      expect(status).to eq(1)
      expect(err).to include("out of date", "deploy/template.yaml")
      expect(File.read(path)).to include("Priority: 11")
    end

    it "refuses a template that lacks a region, naming it" do
      dir = File.join(work, "project")
      FileUtils.cp_r(project, dir)
      path = File.join(dir, "deploy/template.yaml")
      File.write(path, File.read(path).gsub(/^ *# (BEGIN|END) GENERATED site_cdn listener_rules.*\n/, ""))

      expect do
        expect { tool.projection(dir) }.to raise_error(SystemExit) { |e|
          expect(e.message).to include("no BEGIN/END GENERATED site_cdn listener_rules region")
        }
      end
        .to output(/listener_rules/).to_stderr
    end

    it "refuses a template that does not exist" do
      dir = File.join(work, "project")
      FileUtils.cp_r(project, dir)
      FileUtils.rm(File.join(dir, "deploy/template.yaml"))

      expect do
        expect { tool.projection(dir) }.to raise_error(SystemExit) { |e|
          expect(e.message).to include("deploy/template.yaml does not exist")
        }
      end
        .to output(/does not exist/).to_stderr
    end

    it "projects only routes.ts for a project that declares no edge" do
      dir = edited_project do |text|
        text.sub(/\n    # The edge:.*?(?=\n    command "Name")/m, "").gsub(/, alb_rule: "\w+"/, "")
      end

      expect(tool.projection(dir).keys).to eq([File.join(dir, "generated", "routes.ts")])
    end
  end

  describe "a route table the edge refuses" do
    def message_for(&edit)
      dir = edited_project(&edit)
      captured = nil
      expect { tool.projection(dir) }.to raise_error(SystemExit) { |error| captured = error.message }.and output.to_stderr
      captured
    end

    it "refuses a general pattern that comes before a specific one it would shadow" do
      message = message_for do |text|
        general = text[%r{^      member path: "/cms/\*".*\n}]
        text.sub(general, "").sub('      member path: "/cms/_static/*"', "#{general}      member path: \"/cms/_static/*\"")
      end

      expect(message).to include("/cms/_static/* is shadowed by /cms/*", "declare /cms/_static/* before /cms/*")
    end

    it "refuses an origin the Site chapter does not know, and one no EdgeOrigin maps" do
      unknown = message_for do |text|
        text.sub('member rule: "ListenerRuleCms",        priority: 10, origin: "cms"',
                 'member rule: "ListenerRuleCms", priority: 10, origin: "lambda"')
      end
      unmapped = message_for do |text|
        text.sub('      member origin: "cms",     id: "ServerOrigin", target_group: "!Ref CmsTargetGroup"', "")
      end

      expect(unknown).to include('EdgeRule ListenerRuleCms has origin "lambda"', "website, cms, domain, assets")
      expect(unmapped).to include("/cms/* has origin cms, which no EdgeOrigin maps")
    end

    it "refuses a cache class with no policy mapping" do
      message = message_for { |text| text.sub(/      member cache_class: "media".*\n/, "") }

      expect(message).to include("/cms/media/* has cache class media on cms, which no EdgePolicy maps")
    end

    it "refuses two rules with one priority, and a policy reference that is none" do
      duplicate = message_for { |text| text.sub("priority: 21", "priority: 20") }
      bad = message_for do |text|
        text.sub('cache: "caching_optimized",      origin_request', 'cache: "forever",      origin_request')
      end

      expect(duplicate).to include("EdgeRule priority 20 is declared 2 times")
      expect(bad).to include('cache "forever"', "caching_optimized")
    end

    it "refuses a route no rule carries, and a rule that carries no route" do
      uncarried = message_for do |text|
        text.sub('methods: "GET,POST", alb_rule: "ListenerRuleDomainAuth"', 'methods: "GET,POST"')
      end
      empty = message_for do |text|
        spare = 'member rule: "ListenerRuleSpare", priority: 40, origin: "website"'
        text.sub('member rule: "ListenerRuleWebsite",', "#{spare}\n      member rule: \"ListenerRuleWebsite\",")
      end

      expect(uncarried).to include("is served from domain and no rule carries it")
      expect(empty).to include("EdgeRule ListenerRuleSpare carries no route")
    end

    it "refuses a rule that holds more paths than a condition may" do
      message = message_for { |text| text.gsub('alb_rule: "ListenerRuleDomainAuth"', 'alb_rule: "ListenerRuleDomain"') }

      expect(message).to include("EdgeRule ListenerRuleDomain carries 7 paths; a rule holds at most 4 condition values")
    end

    it "refuses a route whose rule forwards to another origin" do
      message = message_for do |text|
        text.sub('methods: "GET,POST,PUT,PATCH,DELETE", alb_rule: "ListenerRuleCms"',
                 'methods: "GET,POST,PUT,PATCH,DELETE", alb_rule: "ListenerRuleDomain"')
      end

      expect(message).to include("/cms/* is served from cms but its rule ListenerRuleDomain forwards to domain")
    end

    it "refuses a route a lower-numbered rule of another origin would answer first" do
      message = message_for do |text|
        text.sub(%r{(      member path: "/\*",.*\n)}) { "#{Regexp.last_match(1)}      member path: \"/webhooks/status\"\n" }
      end

      expect(message).to include("/webhooks/status is served from website but rule ListenerRuleDomain (priority 20) " \
                                 "sends it to domain first")
    end

    it "refuses a table with no row for the default behaviour" do
      message = message_for { |text| text.sub(%r{      member path: "/\*",.*\n}, "") }

      expect(message).to include("needs one row for /*")
    end
  end

  describe "the patterns" do
    let(:pattern) { Hecks::Projections::Site::Edge::Pattern }

    it "reads a parameter as a wildcard, and a prefix as covering what is beneath it" do
      expect(pattern.edge("/blog/:slug.html")).to eq("/blog/*.html")
      expect(pattern.covers?("/cms/*", "/cms/_static/*")).to be(true)
      expect(pattern.covers?("/admin*", "/admin/members")).to be(true)
      expect(pattern.covers?("/cms/_static/*", "/cms/*")).to be(false)
      expect(pattern.covers?("/", "/about")).to be(false)
      expect(pattern.strictly_covers?("/cms/*", "/cms/*")).to be(false)
    end
  end
end

require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "hecks/tools"
require "hecks/tools/site_routes"

# The pure half of the editor's rich-text widget, run under node: `bodyToHtml`, `htmlToBody` and the
# form fields, which are plain JavaScript files in the generated editor and use no DOM. The scenario
# builds a body that holds every field of the document shape, and feeds foreign and hostile HTML in.
BODY_SCENARIO = <<~JS.freeze
  import { bodyToFields, bodyToHtml, emptyBody, safeHref } from "./body_model.js";
  import { htmlToBody, htmlToBodyWithNotes } from "./body_parse.js";

  const span = (text, marks = [], href) => ({ text, marks: marks.map((name) => ({ name })), ...(href ? { href } : {}) });
  const full = { blocks: [
    { kind: "heading", level: 3, align: "center", indent: 1, spans: [span("Title", ["bold", "italic"])] },
    { kind: "paragraph", align: "justify", indent: 8, spans: [span("a "), span("b", ["underline", "strike", "code"]), span("\\n"), span("see", [], "https://example.org/?a=1&b=2")] },
    { kind: "quote", spans: [span("said", ["italic"], "/about")] },
    { kind: "bullet_list", align: "right", items: [
      { spans: [span("one")], depth: 0 }, { spans: [span("two")], depth: 5, list_kind: "numbered_list" } ] },
    { kind: "numbered_list", items: [{ spans: [span("n")], depth: 2 }] },
    { kind: "image", media_ref: "hero-1", alt: "A \\"dog\\"", caption: "Good <dog>" },
    { kind: "divider" },
  ] };

  const hostile = { blocks: [
    { kind: "paragraph", spans: [span("<script>alert(1)</script>", ["bold"]), span("x", [], "javascript:alert(1)"), span("y", [], "JaVaScRiPt:alert(1)"),
      span("z", [], "data:text/html,x"), span("w", [], "//evil.example/"), span("v", [], "/ok\\" onmouseover=\\"alert(1)"), span("t", [], 'https://ok.example/a"b'), span("u", [], "https://ok.example/\\"><img src=x onerror=alert(1)>")] },
    { kind: "image", media_ref: "\\"><img src=x onerror=alert(1)>", alt: "\\"><script>1</script>", caption: "<img src=x onerror=alert(1)>" },
    { kind: "bullet_list", items: [{ spans: [span("<b onclick=1>")], depth: 0 }] },
  ] };

  const out = {};
  out.html = bodyToHtml(full);
  out.roundTrip = JSON.stringify(htmlToBody(out.html)) === JSON.stringify(full);
  out.again = bodyToHtml(htmlToBody(out.html)) === out.html;
  out.deterministic = bodyToHtml(full) === bodyToHtml(structuredClone(full)) && JSON.stringify(htmlToBody(out.html)) === JSON.stringify(htmlToBody(out.html));
  out.empty = [JSON.stringify(emptyBody()), bodyToHtml(emptyBody()), JSON.stringify(htmlToBody(""))];
  out.fields = bodyToFields(full, "body").map(([name, value]) => `${name}=${value}`);
  out.hostile = bodyToHtml(hostile);
  out.hostileAgain = bodyToHtml(htmlToBody(out.hostile));
  out.hrefs = ["/", "/a/b", "http://x.test", "HTTPS://x.test", "mailto:a@b.test", "tel:+1", "//x", "javascript:1", "data:x", "", " /x", "/x y", "ftp://x", "\\\\x"].map((h) => safeHref(h));

  const paste = (html) => htmlToBodyWithNotes(html);
  const word = paste('<div><h5 style="color:red">Big</h5><script>alert(1)</script><p style="font-weight:700">Bold <span style="font-style:italic">it</span><img src="x.png" alt="pic"></p><table><tr><td>cell <a href="javascript:evil()">bad</a></td></tr></table><ul><li>a<ul><li>b<ol><li>c</li></ol></li></ul></li></ul><pre>x\\ny</pre></div>');
  out.word = word;
  out.foreign = htmlToBody("<p>One&nbsp;two &amp; <b>bo<i>ld</i></b> <em>e</em><br>next</p>\\n<div>loose <strong>text</strong></div><p><br></p><hr><blockquote><p>q1</p><p>q2</p></blockquote>");
  out.plain = paste("<p>Just text</p>").notes;
  console.log(JSON.stringify(out));
JS

# Keeps the scenario's answer, so node runs once for every example below.
module BodyNodeResults
  module_function

  # @return [Hash{String => Object}] the block's value, computed on the first call only
  def memo
    @memo ||= yield
  end
end

RSpec.describe "the rich-text body functions of the generated editor, run by node" do
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/editor") }

  def generated
    files = Hecks::Tools::SiteRoutes.projection(project, out: "/work/out", editor: "/work/editor")
    files.select { |path, _| path.include?("/src/ui/body_") && path.end_with?(".js") }
  end

  def run_node
    Dir.mktmpdir("cms_editor_body") do |dir|
      generated.each { |path, text| File.write(File.join(dir, File.basename(path)), text) }
      File.write(File.join(dir, "package.json"), '{"type":"module"}')
      File.write(File.join(dir, "scenario.mjs"), BODY_SCENARIO)
      out, err, status = Open3.capture3({ "NODE_NO_WARNINGS" => "1" }, "node", File.join(dir, "scenario.mjs"))
      raise "the body scenario failed:\n#{err}" unless status.success?

      JSON.parse(out)
    end
  end

  def result(key)
    skip "node is not available" unless system("node", "--version", out: File::NULL, err: File::NULL)

    BodyNodeResults.memo { run_node }.fetch(key)
  end

  describe "bodyToHtml and htmlToBody" do
    it "round-trip a body that holds every field of the document shape" do
      expect(result("roundTrip")).to be(true)
    end

    it "give the same text for the same body, and the same body for the same text", :aggregate_failures do
      expect(result("deterministic")).to be(true)
      expect(result("again")).to be(true)
    end

    it "write a line break as a break, a block's layout as data attributes, and a list as flat items", :aggregate_failures do
      html = result("html")

      expect(html).to include('<h3 data-align="center" data-indent="1">', "</u><br><a href=")
      expect(html).to include('<li data-depth="5" data-list-kind="numbered_list">', 'data-caption="Good &#60;dog&#62;"')
    end

    it "make nothing of an empty body" do
      expect(result("empty")).to eq(['{"blocks":[]}', "", '{"blocks":[]}'])
    end
  end

  describe "escaping" do
    # A tag the editor writes: a known name with only data-, href, rel and class attributes, each value quoted.
    SAFE_TAG = %r{
      \A</?(p|strong|em|u|s|code|a|br|hr|h[1-4]|blockquote|ul|ol|li|figure|figcaption|span)
      (?:\ (?:data-[a-z-]+|href|rel|class)="[^"<>]*")*>\z
    }x

    def hostile = result("hostile")

    def markup_of(html) = html.scan(/<[^>]*>/)

    it "leaves no markup that came from a span, an alt text, a caption or a media key", :aggregate_failures do
      expect(markup_of(hostile)).to all(match(SAFE_TAG))
      expect(hostile).to include("&#60;script&#62;alert(1)&#60;/script&#62;", "&#60;b onclick=1&#62;")
    end

    it "keeps an address that carries a quote inside its attribute", :aggregate_failures do
      expect(hostile).not_to match(/href="[^"]*"\s+onmouseover/)
      expect(hostile.scan(/href="([^"]*)"/).flatten).to all(match(%r{\A(/|https?://)}))
    end

    it "drops every link whose address is not a path, http(s), mailto or tel", :aggregate_failures do
      expect(hostile).not_to match(%r{javascript:|data:|href="//}i)
      expect(hostile.scan("<a ").size).to eq(1)
    end

    it "is as safe after a round trip as before" do
      expect(markup_of(result("hostileAgain"))).to all(match(SAFE_TAG))
    end

    it "allows only a path, http://, https://, mailto: and tel: as an address" do
      allowed = ["/", "/a/b", "http://x.test", "HTTPS://x.test", "mailto:a@b.test", "tel:+1"]

      expect(result("hrefs")).to eq(allowed + Array.new(8))
    end
  end

  describe "HTML from elsewhere" do
    def word = result("word")

    def kinds = word["body"]["blocks"].map { |block| block["kind"] }

    it "is reduced to the nearest block and mark, keeping its text", :aggregate_failures do
      expect(kinds).to eq(%w[heading paragraph paragraph bullet_list paragraph])
      expect(word["body"]["blocks"][0]).to include("level" => 4)
    end

    it "keeps nested lists as flat items with a depth, and a nested ordered list's kind", :aggregate_failures do
      items = word["body"]["blocks"][3]["items"]

      expect(items.map { |item| item["depth"] }).to eq([0, 1, 2])
      expect(items.last).to include("list_kind" => "numbered_list")
    end

    it "says what it reduced, and says nothing when nothing was reduced", :aggregate_failures do
      expect(word["notes"]).to include("<h5> was reduced to a level 4 heading", "<script> content was removed")
      expect(word["notes"]).to include("a table was reduced to paragraphs")
      expect(word["notes"]).to include("a link to an address that is not a path, http(s), mailto or tel was reduced to text")
      expect(result("plain")).to eq([])
    end

    it "reads marks from tags and from styles, and entities, breaks and loose text", :aggregate_failures do
      blocks = result("foreign")["blocks"]

      expect(blocks.map { |block| block["kind"] }).to eq(%w[paragraph paragraph paragraph divider quote quote])
      expect(blocks[0]["spans"].map { |span| span["text"] }).to eq(["One two & ", "bo", "ld", " ", "e", "\n", "next"])
    end
  end

  describe "the form fields" do
    it "are named by dotted path, the encoding the editor's other lists use", :aggregate_failures do
      fields = result("fields")

      expect(fields).to include("body.blocks.0.kind=heading", "body.blocks.0.spans.0.marks.1.name=italic")
      expect(fields).to include("body.blocks.3.items.1.list_kind=numbered_list")
      expect(fields).to include("body.blocks.1.spans.3.href=https://example.org/?a=1&b=2", "body.blocks.5.media_ref=hero-1")
    end
  end
end

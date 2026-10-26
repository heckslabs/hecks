require "spec_helper"
require "json"
require "open3"
require "securerandom"
require "tmpdir"
require "hecks/tools"
require "hecks/tools/site_routes"

# Checks the generated `redirect_host` function against what CloudFront's JavaScript runtime
# accepts, which `node` does not tell us: CloudFront compiles every regular expression with its own
# engine and refuses one that names a surrogate code point, so a function that Node runs fails on
# every request there (`pcre_compile(...) failed: disallowed Unicode code point`).
#
# The first group is a static guard that always runs. The second runs the function through
# `aws cloudfront test-function` on a throwaway function and is left out unless it is asked for by
# tag (`--tag cloudfront`) and the AWS CLI has credentials.
RSpec.describe "the generated redirect_host function, for CloudFront's runtime" do
  let(:rendered) { Hecks::Projections::Site::Edge::FunctionCode.code(fixture_function) }
  let(:fixture_function) do
    registry = Hecks::Tools::SiteRoutes.registry_for(File.join(InMemoryDomain::ROOT, "spec/fixtures/site/studio"))
    chapter = Hecks::Projections::Site::Table.chapter(registry)
    table = Hecks::Projections::Site::Table.read(chapter, registry: registry)
    vocabulary = Hecks::Projections::Site::Table.vocabulary(registry)
    Hecks::Projections::Site::Edge.read(chapter, table: table, vocabulary: vocabulary).function("HostRedirect")
  end

  PCRE_ERROR = "CloudFront's regex engine fails the whole function at compile time on a surrogate code point " \
               "(SyntaxError: pcre_compile(...) failed: disallowed Unicode code point (>= 0xd800 && <= 0xdfff)), " \
               "which Node accepts; build the pair in code (charCodeAt) instead of naming it in a pattern".freeze
  SURROGATE_ESCAPE = /\\u(?:[dD][89a-fA-F][0-9a-fA-F]{2}|\{0*[dD][89a-fA-F][0-9a-fA-F]{2}\})/
  # A surrogate written as itself is not valid UTF-8, so it is looked for as its three bytes.
  SURROGATE_BYTES = /\xED[\xA0-\xBF][\x80-\xBF]/n
  REGEX_LITERAL = %r~(?<=[(=,:!&|?{;]|return)\s*/(?:\\.|\[(?:\\.|[^\]\\\n])*\]|[^/\\\n\[])+/[gimsuy]*~
  NEW_REGEXP = /new\s+RegExp\([^)]*\)/

  # The text of every regular expression in `js`: literals (with line comments and string
  # literals taken out first, so a "/" in either is not read as one) and `new RegExp(...)` calls.
  def patterns_in(source)
    constructed = source.scan(NEW_REGEXP)
    bare = source.gsub(%r{//[^\n]*}, "").gsub(/"(?:\\.|[^"\\\n])*"/, '""')
    constructed + bare.scan(REGEX_LITERAL)
  end

  def surrogate_patterns(source)
    return [source] if source.b.match?(SURROGATE_BYTES)

    patterns_in(source).grep(SURROGATE_ESCAPE)
  end

  describe "regular expressions" do
    it "finds the patterns of the rendered function (the guard looks at something)" do
      expect(patterns_in(rendered).size).to be >= 3
    end

    it "names no surrogate code point in any pattern" do
      expect(surrogate_patterns(rendered)).to be_empty, PCRE_ERROR
    end

    {
      "the pattern that shipped"      => 't.replace(/%(?![0-9A-Fa-f]{2})|[\uD800-\uDBFF][\uDC00-\uDFFF]|[^A-Za-z0-9]/g, f);',
      "a new RegExp string"           => 'var r = new RegExp("[\\\\uD800-\\\\uDBFF]", "g");',
      "a braced escape"               => 'return s.replace(/[\u{D83D}]/g, f);',
      "a surrogate written as itself" => "return s.replace(/[\xED\xA0\xBD]/g, f);".b
    }.each do |label, source|
      it "catches #{label} (the guard can fail)" do
        expect(surrogate_patterns(source).size).to eq(1)
      end
    end

    it "does not mistake a slash in a string or a comment for a pattern" do
      expect(patterns_in(%(var a = "/x/ y"; // /\\uD800/ here\n))).to be_empty
    end
  end

  describe "against CloudFront's test-function", :cloudfront do
    EDGE_TEST_FUNCTION_PREFIX = "tmp-hecks-edge-test-".freeze

    def aws(*args)
      out, err, status = Open3.capture3("aws", *args)
      raise "aws #{args.first(2).join(" ")} failed: #{err}" unless status.success?

      out.empty? ? {} : JSON.parse(out)
    end

    def event(host_name, uri, querystring: {}, method: "GET")
      { version: "1.0", context: { eventType: "viewer-request" }, viewer: { ip: "198.51.100.1" },
        request: { method: method, uri: uri, querystring: querystring,
                   headers: { host: { value: host_name } }, cookies: {} } }
    end

    def tested(name, etag, dir, event_hash)
      file = File.join(dir, "event.json")
      File.write(file, JSON.generate(event_hash))
      result = aws("cloudfront", "test-function", "--name", name, "--if-match", etag, "--stage", "DEVELOPMENT",
                   "--event-object", "fileb://#{file}", "--output", "json").fetch("TestResult")
      [result.fetch("FunctionErrorMessage", ""), JSON.parse(result.fetch("FunctionOutput"))]
    end

    def delete(name)
      etag = aws("cloudfront", "describe-function", "--name", name, "--stage", "DEVELOPMENT", "--output", "json").fetch("ETag")
      aws("cloudfront", "delete-function", "--name", name, "--if-match", etag)
    end

    around do |example|
      @name = "#{EDGE_TEST_FUNCTION_PREFIX}#{SecureRandom.hex(4)}"
      created = false
      Dir.mktmpdir("cloudfront_function") do |dir|
        @dir = dir
        File.write(File.join(dir, "function.js"), rendered)
        @etag = aws("cloudfront", "create-function", "--name", @name, "--function-config",
                    "Comment=throwaway,Runtime=cloudfront-js-2.0", "--function-code", "fileb://#{dir}/function.js",
                    "--output", "json").fetch("ETag")
        created = true
        example.run
      ensure
        delete(@name) if created
      end
    end

    before do
      _, status = Open3.capture2("aws", "sts", "get-caller-identity")
      skip "the cloudfront tag was asked for but the AWS CLI has no credentials" unless status.success?
    end

    def host = fixture_function.host

    def alias_host = fixture_function.alias_list.first

    def path = fixture_function.path_list.first

    def test_event(event_hash) = tested(@name, @etag, @dir, event_hash)

    it "compiles and passes the canonical host through" do
      expect(test_event(event(host, path))).to match(["", a_hash_including("request")])
    end

    it "redirects an alias with the query intact" do
      error, output = test_event(event(alias_host, path, querystring: { a: { value: "1" } }))
      response = output.fetch("response")

      expect([error, response["statusCode"], response.dig("headers", "location", "value"),
              response.dig("headers", "cache-control", "value")]).to eq(["", 302, "https://#{host}#{path}?a=1", "no-store"])
    end

    it "encodes an astral character in the query" do
      error, output = test_event(event(alias_host, path, querystring: { e: { value: "\u{1F600}" } }))

      expect([error, output.dig("response", "headers", "location", "value")]).to eq(["", "https://#{host}#{path}?e=%F0%9F%98%80"])
    end
  end
end

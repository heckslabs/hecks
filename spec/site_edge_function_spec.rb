require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "hecks/tools"
require "hecks/tools/site_routes"

# The edge function of the Site bluebook (ADR 0115): a route's `edge:` names an `EdgeFunction` row,
# the projection attaches the function to that route's behaviour and writes the function into the
# template's `edge_functions` region. spec/fixtures/site/studio is the neutral sample project.
RSpec.describe "the Site chapter's edge functions" do
  let(:tool)    { Hecks::Tools::SiteRoutes }
  let(:project) { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/studio") }
  let(:work)    { Dir.mktmpdir("site_edge_function") }

  after { FileUtils.rm_rf(work) }

  def site = Hecks::Projections::Site

  def cdn = Hecks::Projections::Deploy::Fargate::Cdn

  FUNCTION_ROW = %r{^ *member name: "HostRedirect".*?"/login,/auth/start"\n}m
  FUNCTION_OBJECT = /\n    # A viewer-request function.*?(?=\n    command "Name")/m

  # The route table text with the EdgeFunction row and every `edge:` taken out.
  def without_functions(text) = text.sub(FUNCTION_OBJECT, "").gsub(', edge: "HostRedirect"', "")

  # A copy of the sample project whose route table is changed by `edit`, a block given the text.
  def edited_project(&)
    dir = Dir.mktmpdir("project", work)
    FileUtils.cp_r(Dir.children(project).map { |name| File.join(project, name) }, dir)
    path = File.join(dir, "bluebook/studio_site.bluebook")
    File.write(path, yield(File.read(path)))
    dir
  end

  def template_edited(dir, &)
    path = File.join(dir, "deploy/template.yaml")
    File.write(path, yield(File.read(path)))
  end

  def projected(dir) = tool.projection(dir, out: "/work/out").fetch("/work/out/deploy/template.yaml")

  # The refusal message of projecting `dir`.
  def refusal(dir)
    captured = nil
    expect { tool.projection(dir) }.to raise_error(SystemExit) { |error| captured = error.message }.and output.to_stderr
    captured
  end

  def edge_of(dir)
    registry = tool.registry_for(dir)
    chapter = site::Table.chapter(registry)
    table = site::Table.read(chapter, registry: registry)
    [site::Edge.read(chapter, table: table, vocabulary: site::Table.vocabulary(registry)), table]
  end

  def function(**fields)
    base = { name: "HostRedirect", kind: "redirect_host", host: "app.example.test",
             aliases: "www.example.test", paths: "/login,/auth/start" }
    site::Edge::Function.new(**base, **fields)
  end

  describe "the route attribute" do
    it "is read into the row, and is nil on a route that names none", :aggregate_failures do
      _, table = edge_of(project)
      rows = table.rows.to_h { |row| [row.path, row.edge] }

      expect(rows.fetch("/login")).to eq("HostRedirect")
      expect(rows.fetch("/logout")).to be_nil
    end

    it "refuses an edge that is not a logical id" do
      dir = edited_project { |text| text.sub('edge: "HostRedirect"', 'edge: "Host Redirect"') }

      expect(refusal(dir)).to include('/login has edge "Host Redirect"; an edge is the logical id of an EdgeFunction row')
    end

    it "refuses an edge that is not a string" do
      dir = edited_project { |text| text.sub('edge: "HostRedirect"', "edge: 3") }

      expect(refusal(dir)).to include("/login has edge 3; edge is a String")
    end
  end

  describe "the EdgeFunction rows" do
    def message_for(from, to)
      refusal(edited_project { |text| text.sub(from, to) })
    end

    it "reads the row into a function with its lists", :aggregate_failures do
      found = edge_of(project).first.function("HostRedirect")

      expect(found.host).to eq("app.example.test")
      expect(found.alias_list).to eq(["www.example.test"])
      expect(found.path_list).to eq(["/login", "/auth/start"])
    end

    it "refuses a kind outside the set, naming the set" do
      expect(message_for('kind: "redirect_host"', 'kind: "external"')).to include(
        'EdgeFunction HostRedirect has kind "external"; kind is one of redirect_host'
      )
    end

    it "refuses a host that is not a lowercase hostname" do
      expect(message_for('host: "app.example.test"', 'host: "App.Example.test"')).to include(
        'EdgeFunction HostRedirect has host "App.Example.test"; a host is a lowercase hostname'
      )
    end

    it "refuses an alias that is not a hostname" do
      expect(message_for('aliases: "www.example.test"', 'aliases: "www.example.test,not a host"')).to include(
        'EdgeFunction HostRedirect has alias "not a host"; an alias is a lowercase hostname'
      )
    end

    it "refuses an alias that is the host" do
      expect(message_for('aliases: "www.example.test"', 'aliases: "app.example.test"')).to include(
        "has alias app.example.test, which is its host; an alias is another host"
      )
    end

    it "refuses a path that is not an exact path" do
      expect(message_for('paths: "/login,/auth/start"', 'paths: "/login,/auth/*"')).to include(
        'EdgeFunction HostRedirect has path "/auth/*"; a path is exact, starts with /'
      )
    end

    it "refuses a row with no path to watch" do
      expect(message_for('paths: "/login,/auth/start"', 'paths: ""')).to include(
        "EdgeFunction HostRedirect needs at least one path to watch"
      )
    end

    it "refuses a row that leaves a field out" do
      expect(message_for(%(\n             aliases: "www.example.test",), "")).to include("EdgeFunction row 1 needs aliases")
    end

    it "refuses a field the row does not have" do
      expect(message_for('kind: "redirect_host",', 'kind: "redirect_host", status: "302",')).to include(
        "EdgeFunction row 1 has no field status; fields are name, kind, host, aliases, paths"
      )
    end

    it "refuses a name that is not a logical id" do
      expect(message_for('name: "HostRedirect"', 'name: "Host-Redirect"')).to include(
        "EdgeFunction Host-Redirect is not a logical id"
      )
    end

    it "refuses a name longer than a function name allows" do
      long = "A#{"b" * 40}"

      dir = edited_project { |text| text.gsub("HostRedirect", long) }

      expect(refusal(dir)).to include("#{long} is longer than 40 characters")
    end

    it "refuses a name declared twice" do
      dir = edited_project do |text|
        row = text[FUNCTION_ROW]
        text.sub(row, "#{row}#{row}")
      end

      expect(refusal(dir)).to include("EdgeFunction HostRedirect is declared 2 times")
    end

    it "refuses two names that would become one function name" do
      dir = edited_project do |text|
        row = text[FUNCTION_ROW]
        text.sub(row, "#{row}#{row.sub("HostRedirect", "HOstRedirect")}")
      end

      expect(refusal(dir)).to include("HostRedirect and HOstRedirect would both be named host-redirect")
    end

    it "refuses a route that names a function no row declares" do
      expect(message_for('edge: "HostRedirect"', 'edge: "Elsewhere"')).to include(
        "/login names edge Elsewhere, which no EdgeFunction declares"
      )
    end

    it "refuses a function that no route names" do
      dir = edited_project { |text| text.gsub(', edge: "HostRedirect"', "") }

      expect(refusal(dir)).to include("EdgeFunction HostRedirect is named by no route")
    end

    it "refuses an edge on a route the CDN never sees" do
      dir = edited_project { |text| text.sub("cdn: false,", %(cdn: false, edge: "HostRedirect",)) }

      expect(refusal(dir)).to include("/internal/ping names edge HostRedirect and has cdn false")
    end

    it "refuses a route that names an edge when the project declares no edge rows" do
      dir = edited_project { |text| text.sub(/\n    # The edge:.*?(?=\n    command "Name")/m, "").gsub(/, alb_rule: "\w+"/, "") }

      expect(refusal(dir)).to include("/login names edge HostRedirect, which no EdgeFunction declares")
    end

    it "reports every problem together", :aggregate_failures do
      dir = edited_project { |text| text.sub("redirect_host", "x").sub("/login,/auth/start", "") }
      message = refusal(dir)

      expect(message).to include('has kind "x"')
      expect(message).to include("needs at least one path")
    end
  end

  describe "the behaviours" do
    def behaviours_of(dir) = edge_of(dir).first.behaviours.to_h { |entry| [entry[:path], entry] }

    it "carries the function on the routes that name it, and on no other", :aggregate_failures do
      found = behaviours_of(project)

      expect(found.fetch("/login")[:edge_function]).to eq("HostRedirect")
      expect(found.fetch("/auth/*")[:edge_function]).to eq("HostRedirect")
      expect(found.fetch("/logout")).not_to have_key(:edge_function)
    end

    it "keeps a route whose behaviour matches its cover's except for the function", :aggregate_failures do
      without = behaviours_of(project)
      named = edited_project { |text| text.sub('member path: "/about", ', %(member path: "/about", edge: "HostRedirect", )) }
      with = behaviours_of(named)

      expect(without).not_to have_key("/about")
      expect(with.fetch("/about")[:edge_function]).to eq("HostRedirect")
    end

    it "keeps a route with a function under a broader route that has none" do
      dir = edited_project do |text|
        text.sub('member path: "/api/*",            kind: "endpoint", methods: "GET,POST", compress: false',
                 'member path: "/api/*", kind: "endpoint", methods: "GET,POST", compress: false, edge: "HostRedirect"')
      end

      expect(behaviours_of(dir).fetch("/api/*")[:edge_function]).to eq("HostRedirect")
    end

    it "folds a route into a cover that names the same function" do
      dir = edited_project do |text|
        text.sub('      member path: "/logout", ', %(      member path: "/auth/start", edge: "HostRedirect", ))
      end

      expect(behaviours_of(dir)).not_to have_key("/auth/start")
    end

    it "refuses two routes on one edge pattern that name different functions" do
      dir = edited_project do |text|
        text.sub('      member path: "/old-portfolio",',
                 %(      member path: "/pay/*", render: "ssr", edge: "HostRedirect"\n      member path: "/old-portfolio",))
      end

      expect(refusal(dir)).to include("/pay/* is declared by 2 routes that resolve to different behaviours")
    end
  end

  describe "the behaviour lines" do
    let(:entry) do
      { path: "/login", origin: "ServerOrigin", viewer_protocol: "https-only", methods: %w[GET HEAD], compress: true,
        cache_policy: ["!Ref Cache", nil] }
    end

    it "writes a viewer-request association for a behaviour that names a function" do
      lines = cdn.behavior_lines(nil, entry.merge(edge_function: "HostRedirect"), "  ")

      expect(lines.last(3)).to eq(["    FunctionAssociations:", "      - EventType: viewer-request",
                                   "        FunctionARN: !GetAtt HostRedirect.FunctionARN"])
    end

    it "writes none for a behaviour that names none" do
      expect(cdn.behavior_lines(nil, entry, "  ").join("\n")).not_to include("FunctionAssociations")
    end

    it "writes it on the default behaviour too" do
      lines = cdn.behavior_lines("DefaultCacheBehavior", entry.merge(edge_function: "Gate"), "")

      expect(lines).to include("  FunctionAssociations:", "      FunctionARN: !GetAtt Gate.FunctionARN")
    end
  end

  describe "the edge_functions region" do
    let(:regions) { regions_of(project) }

    def regions_of(dir)
      chapter = site::Table.chapter(tool.registry_for(dir))
      edge, table = edge_of(dir)
      Hecks::Projector.call(:site_cdn, bluebook: chapter, options: { table: table, edge: edge })
    end

    it "is written once for each function row", :aggregate_failures do
      block = regions.fetch("edge_functions")

      expect(block).to start_with("HostRedirect:\n  Type: AWS::CloudFront::Function\n")
      expect(block.scan(/^\S+:$/)).to eq(["HostRedirect:"])
    end

    it "names the function from the stack, publishes it and picks the runtime", :aggregate_failures do
      block = regions.fetch("edge_functions")

      expect(block).to include('Name: !Sub "${AWS::StackName}-host-redirect"', "AutoPublish: true", "Runtime: cloudfront-js-2.0")
    end

    it "is absent when the project declares no EdgeFunction rows" do
      dir = edited_project { |text| without_functions(text) }

      expect(regions_of(dir).keys).not_to include("edge_functions")
    end

    it "is valid YAML whose FunctionCode is the generated code", :aggregate_failures do
      parsed = YAML.safe_load(regions.fetch("edge_functions"))

      expect(parsed.fetch("HostRedirect").dig("Properties", "FunctionCode")).to eq(site::Edge::FunctionCode.code(function))
      expect(parsed.fetch("HostRedirect").dig("Properties", "FunctionConfig", "Runtime")).to eq("cloudfront-js-2.0")
    end
  end

  describe "values that would break out of the function" do
    let(:code) { site::Edge::FunctionCode }

    hostile_hosts = {
      "a double quote"        => %(app.example.test"; evil(); "),
      "a backslash"           => "app.example.test\\",
      "a script end tag"      => "app.example.test</script>",
      "a template expression" => "${AWS::StackName}.example.test",
      "a newline"             => "app.example.test\nCommand: x",
      "unicode"               => "\u00e4pp.example.test",
      "uppercase"             => "App.Example.Test",
      "a port"                => "app.example.test:8080"
    }
    hostile_hosts.each do |what, host|
      it "refuses #{what} in the host", :aggregate_failures do
        expect(code.host?(host)).to be(false)
        expect { code.code(function(host: host)) }.to raise_error(ArgumentError, /outside the hostname and path shapes/)
      end
    end

    hostile_paths = [%(/login"), "/login\\", "/login</script>", "/${x}", "/login\n/other", "/l\u00f6gin", "/login?x=1",
                     "/login#a", "/a b", "login", "/a%2Fb", ""]
    hostile_paths.each do |path|
      it "refuses the path #{path.inspect}", :aggregate_failures do
        expect(code.path?(path)).to be(false)
        expect { code.code(function(paths: path)) }.to raise_error(ArgumentError)
      end
    end

    it "refuses a hostile alias" do
      expect { code.code(function(aliases: 'www.example.test","x')) }.to raise_error(ArgumentError, /outside/)
    end

    it "keeps a placeholder inside a value from being filled again", :aggregate_failures do
      expect(code.host?("__WATCHED__.example.test")).to be(false)
      expect { code.code(function(host: "__ALIASES__")) }.to raise_error(ArgumentError)
    end

    it "accepts the shapes it is meant to", :aggregate_failures do
      expect(code.host?("app.example.test")).to be(true)
      expect(code.path?("/auth/start")).to be(true)
      expect(code.path?("/a-b_c.d~e/f")).to be(true)
    end

    it "writes only the three values, as JSON strings, into the template", :aggregate_failures do
      text = code.code(function)

      expect(text).to include('var canonical = "app.example.test";', 'var aliases = ["www.example.test"];',
                              'var watched = ["/login","/auth/start"];')
      expect(text).not_to match(/__[A-Z]+__/)
    end
  end

  describe "the template and --check" do
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

    def copied
      dir = Dir.mktmpdir("project", work)
      FileUtils.cp_r(Dir.children(project).map { |name| File.join(project, name) }, dir)
      dir
    end

    it "refuses a template without the region, naming its markers" do
      dir = copied
      template_edited(dir) { |text| text.gsub(/^ *# (BEGIN|END) GENERATED site_cdn edge_functions.*\n/, "") }

      expect(refusal(dir)).to include("has no BEGIN/END GENERATED site_cdn edge_functions region")
    end

    it "refuses a region left behind when the project declares no EdgeFunction row" do
      dir = edited_project { |text| without_functions(text) }

      expect(refusal(dir)).to include("has a BEGIN/END GENERATED site_cdn edge_functions region, and the project declares no")
    end

    it "accepts a template that has no region when the project declares no function" do
      dir = edited_project { |text| without_functions(text) }
      template_edited(dir) { |text| text.gsub(/^ *# (BEGIN|END) GENERATED site_cdn edge_functions.*\n\n?/, "") }

      expect(run(dir).first).to eq(0)
    end

    it "with --check names a template whose function region was edited by hand", :aggregate_failures do
      dir = copied
      run(dir)
      template_edited(dir) { |text| text.sub("AutoPublish: true", "AutoPublish: false") }

      expect(run(dir, "--check").values_at(0, 2)).to match([1, a_string_including("out of date", "deploy/template.yaml")])
    end

    it "with --check finds the template current after a run" do
      dir = copied
      run(dir)

      expect(run(dir, "--check").first).to eq(0)
    end

    it "writes the function into the region of the template", :aggregate_failures do
      text = projected(copied)

      expect(text).to include("  HostRedirect:\n    Type: AWS::CloudFront::Function")
      expect(text).to include("FunctionARN: !GetAtt HostRedirect.FunctionARN")
    end
  end
end

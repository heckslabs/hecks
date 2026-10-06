require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "yaml"
require "hecks/tools"
require "hecks/tools/site_routes"

# The address the stand-in host answers on in the node scripts below.
ADMIN_NODE_HOST = "http://host.test".freeze

# The fake `fetch` and `signedIn` helpers every node script below starts from. The script gets
# `admin`, and `host(handlers)`, which builds a fake fetch and a list of what it was asked.
ADMIN_NODE_PRELUDE = <<~JS.freeze
  import * as admin from "./admin.ts";

  // handlers: path => (cookie) => [status, body]
  function host(handlers) {
    const asked = [];
    const fetch = async (url, init) => {
      const path = new URL(url).pathname;
      const cookie = init.headers.Cookie;
      asked.push(path + " " + cookie);
      const [status, body] = handlers[path] ? handlers[path](cookie) : [404, {}];
      return { ok: status >= 200 && status < 300, status, json: async () => body };
    };
    return { fetch, asked };
  }
  const signedIn = (email, role, disabled) => ({
    "/accounts/me": () => [200, { email }],
    "/members": () => [200, [{ email, role, disabled }]],
  });
JS

ADMIN_NODE_VISITOR_SCRIPT = <<~JS.freeze
  const none = host({});
  admin.configureAdmin({ host: "#{ADMIN_NODE_HOST}", fetch: none.fetch });
  const gate = (path) => admin.adminGate(path, undefined);
  console.log(JSON.stringify({
    home: await gate("/"), events: await gate("/events"), login: await gate("/admin-login"),
    loginHtml: await gate("/admin-login.html"), admin: await gate("/admin"), inbox: await gate("/admin-inbox"),
    cms: await gate("/cms/admin"), sso: await gate("/api/cms-sso"), preview: await gate("/admin-preview/events"),
    asked: none.asked,
  }));
JS

ADMIN_NODE_VISITOR_VERDICTS = {
  "home" => { "allow" => true }, "events" => { "allow" => true }, "login" => { "allow" => true },
  "loginHtml" => { "allow" => true },
  "admin" => { "allow" => false, "redirect" => "/admin-login" },
  "inbox" => { "allow" => false, "redirect" => "/admin-login" },
  "cms" => { "allow" => false, "redirect" => "/admin-login" },
  "sso" => { "allow" => false, "redirect" => "/admin-login" },
  "preview" => { "allow" => false, "status" => 401 }
}.freeze

ADMIN_NODE_SPECIFICITY_SCRIPT = <<~JS.freeze
  admin.configureAdmin({ host: "#{ADMIN_NODE_HOST}", fetch: host({}).fetch });
  const gate = (path) => admin.adminGate(path, undefined);
  console.log(JSON.stringify({
    literalAdminPage: await gate("/admin-orders.html"),
    tiedWithGenericPage: await gate("/admin-x.html"),
    genericPage: await gate("/anything.html"),
  }));
JS

ADMIN_NODE_SPECIFICITY_VERDICTS = {
  "literalAdminPage"    => { "allow" => false, "redirect" => "/admin-login" },
  "tiedWithGenericPage" => { "allow" => false, "redirect" => "/admin-login" },
  "genericPage"         => { "allow" => true }
}.freeze

ADMIN_NODE_ROLES_SCRIPT = <<~JS.freeze
  const verdict = async (handlers) => {
    const fake = host(handlers);
    admin.configureAdmin({ host: "#{ADMIN_NODE_HOST}", fetch: fake.fetch });
    return (await admin.adminGate("/admin", "abc")).allow;
  };
  console.log(JSON.stringify({
    admin: await verdict(signedIn("A@Example.org", "Admin", false)),
    owner: await verdict(signedIn("a@example.org", "Owner", undefined)),
    member: await verdict(signedIn("a@example.org", "Member", false)),
    disabled: await verdict(signedIn("a@example.org", "Admin", true)),
    refused: await verdict({ "/accounts/me": () => [401, {}], "/members": () => [401, {}] }),
  }));
JS

ADMIN_NODE_ENVIRONMENT_SCRIPT = <<~JS.freeze
  const fake = host(signedIn("a@example.org", "Admin", false));
  process.env.CLUB_DOMAIN_SERVICE_URL = "#{ADMIN_NODE_HOST}/";
  admin.configureAdmin({ fetch: fake.fetch });
  const email = await admin.currentAdminEmail("abc");
  console.log(JSON.stringify({ email, asked: fake.asked.sort() }));
JS

ADMIN_NODE_TTL_SCRIPT = <<~JS.freeze
  const fake = host(signedIn("a@example.org", "Admin", false));
  admin.configureAdmin({ host: "#{ADMIN_NODE_HOST}", fetch: fake.fetch });
  await Promise.all([admin.currentAdminEmail("abc"), admin.currentAdminEmail("abc")]);
  await admin.currentAdminEmail("abc");
  const remembered = fake.asked.length;
  admin.forgetAdminSessions();
  await admin.currentAdminEmail("abc");
  console.log(JSON.stringify({ remembered, afterForget: fake.asked.length }));
JS

ADMIN_NODE_FAILED_READ_SCRIPT = <<~JS.freeze
  let failing = true;
  const fake = host({
    "/accounts/me": () => (failing ? [500, {}] : [200, { email: "a@example.org" }]),
    "/members": () => [200, [{ email: "a@example.org", role: "Admin" }]],
  });
  admin.configureAdmin({ host: "#{ADMIN_NODE_HOST}", fetch: fake.fetch });
  const first = await admin.currentAdminEmail("abc");
  failing = false;
  admin.forgetAdminSessions();
  console.log(JSON.stringify({ first, second: await admin.currentAdminEmail("abc") }));
JS

ADMIN_NODE_SSO_SCRIPT = <<~JS.freeze
  const ok = host({ "/accounts/sso-token": () => [200, { token: "t o k" }] });
  admin.configureAdmin({ host: "#{ADMIN_NODE_HOST}", fetch: ok.fetch });
  const signed = [await admin.ssoRedirect("abc"), await admin.ssoRedirect("abc", "/cms/admin/posts")];
  const none = await admin.ssoRedirect(undefined);
  admin.configureAdmin({ host: "#{ADMIN_NODE_HOST}", fetch: host({}).fetch });
  console.log(JSON.stringify({ signed, none, refused: await admin.ssoRedirect("abc") }));
JS

# The admin sign-in module a project gets when its chapter declares an `Admin` row. The sample is
# spec/fixtures/site/members; its golden sits in spec/fixtures/site/members/expected
# (`GOLDEN=rewrite` regenerates it, to be read in the diff).
RSpec.describe "the admin sign-in module" do
  let(:tool)     { Hecks::Tools::SiteRoutes }
  let(:members)  { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/members") }
  let(:expected) { File.join(members, "expected") }
  let(:work)     { Dir.mktmpdir("site_admin") }

  after { FileUtils.rm_rf(work) }

  def studio = File.join(InMemoryDomain::ROOT, "spec/fixtures/site/studio")

  def projected(project = members, **options) = tool.projection(project, out: "/work/out", **options)

  def admin_ts(project = members) = projected(project).fetch("/work/out/admin.ts")

  # A copy of the members project whose route chapter is changed by the block, given its text.
  def edited_members
    dir = File.join(work, "project")
    FileUtils.cp_r(members, dir)
    FileUtils.rm_rf(File.join(dir, "expected"))
    path = File.join(dir, "bluebook/members_site.bluebook")
    File.write(path, yield(File.read(path)))
    dir
  end

  def edited_members_sub(from, to) = edited_members { |text| text.sub(from, to) }

  def refusal(project, **options)
    message = nil
    expect { tool.projection(project, **options) }.to raise_error(SystemExit) { |error| message = error.message }
      .and output.to_stderr
    message
  end

  # The golden at `path`, rewritten from `text` first when `GOLDEN=rewrite` asks for it.
  def golden_for(path, text)
    if ENV["GOLDEN"] == "rewrite"
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
    end
    File.read(path)
  end

  def node? = system("node", "--version", out: File::NULL, err: File::NULL)

  # What `node --check` reports for each of the named texts, written to a directory of their own.
  def node_failures(texts, *flags)
    Dir.mktmpdir("node_check") do |dir|
      texts.filter_map do |name, text|
        file = File.join(dir, File.basename(name))
        File.write(file, text)
        _out, err, status = Open3.capture3({ "NODE_NO_WARNINGS" => "1" }, "node", *flags, "--check", file)
        "#{name}: #{err}" unless status.success?
      end
    end
  end

  describe "the projection" do
    it "equals the committed golden, byte for byte" do
      expect(admin_ts).to eq(golden_for(File.join(expected, "admin.ts"), admin_ts))
    end

    it "is the same text every time" do
      first = admin_ts

      expect(admin_ts).to eq(first)
    end

    it "is written beside the route table, with the extension the tool is given", :aggregate_failures do
      files = projected(extension: "mts")

      expect(files.keys).to contain_exactly("/work/out/routes.mts", "/work/out/admin.mts")
      expect(files.fetch("/work/out/admin.mts")).to include('from "./routes.mts"')
    end

    it "is not written by a project that declares no admin row" do
      expect(projected(studio).keys).to eq(["/work/out/routes.ts", "/work/out/deploy/template.yaml"])
    end

    it "fills what the row leaves out", :aggregate_failures do
      text = admin_ts

      expect(text).to include('accountPath: "/accounts/me"', 'membersPath: "/members"', "sessionMaxAge: 1209600")
      expect(text).to include('ssoTokenPath: "/accounts/sso-token"', 'ssoTarget: "/cms/api/sso"', "timeoutMs: 5000")
    end

    it "names the values the row sets" do
      expect(admin_ts).to include('sessionCookie: "club_session"', 'hostEnv: "CLUB_DOMAIN_SERVICE_URL"',
                                  'roles: ["Admin", "Owner"]', "verdictTtlMs: 2000")
    end
  end

  describe "an admin row the table contradicts" do
    it "is refused when the login page is not a route" do
      dir = edited_members { |text| text.sub('login: "/admin-login"', 'login: "/sign-in"') }

      expect(refusal(dir)).to include("Admin login /sign-in is not a route of the table")
    end

    it "is refused when the login page is not public" do
      dir = edited_members do |text|
        text.sub('member path: "/admin-login",   render: "ssr", cache: "no_store", methods: "GET", indexable: false',
                 'member path: "/admin-login",   render: "ssr", auth: "admin", methods: "GET", indexable: false')
      end

      expect(refusal(dir)).to include("the login page must be public")
    end

    it "is refused when the hand-off is not an admin endpoint" do
      dir = edited_members do |text|
        text.sub('member path: "/api/cms-sso",   kind: "endpoint", auth: "admin"', 'member path: "/api/cms-sso",   kind: "page"')
      end

      expect(refusal(dir)).to include("Admin sso /api/cms-sso is public; it must be admin", "it must be an endpoint")
    end

    it "is refused for a field it does not have, and for a missing required one" do
      dir = edited_members do |text|
        text.sub('sso: "/api/cms-sso",', 'sso: "/api/cms-sso", colour: "red",').sub('session_cookie: "club_session", ', "")
      end

      expect(refusal(dir)).to include("Admin row has no field colour", "Admin row needs session_cookie")
    end

    it "is refused for a path with no leading slash, and for no roles", :aggregate_failures do
      dir = edited_members { |text| text.sub('roles: "Admin,Owner"', 'roles: " , "') }
      expect(refusal(dir)).to include("Admin roles name no role")

      dir = edited_members { |text| text.sub('host_default: "http://127.0.0.1:4500"', 'host_default: "http://127.0.0.1:4500", account_path: "accounts/me"') }
      expect(refusal(dir)).to include('Admin account_path "accounts/me" must start with a slash')
    end
  end

  describe "the content system's half" do
    def cms_files(project = members) = tool.projection(project, out: "/work/out", cms: "/work/cms")

    def cms_text(path, project = members) = cms_files(project).fetch("/work/cms/#{path}")

    let(:paths) { %w[auth/membership.ts auth/sessionStrategy.ts endpoints/sso.ts collections/Users.ts] }

    it "is four files under the directory --cms names, beside the site's own output", :aggregate_failures do
      files = cms_files

      expect(files.keys).to include("/work/out/routes.ts", "/work/out/admin.ts")
      expect(files.keys.grep(%r{\A/work/cms/})).to match_array(paths.map { |path| "/work/cms/#{path}" })
    end

    it "is not written unless --cms is named" do
      expect(projected.keys.grep(%r{/cms/})).to be_empty
    end

    it "equals the committed goldens, byte for byte" do
      paths.each do |path|
        text = cms_text(path)
        expect(text).to eq(golden_for(File.join(expected, "cms", path), text)), path
      end
    end

    it "leaves no placeholder behind" do
      paths.each do |path|
        expect(cms_text(path)).not_to match(/__[A-Z_]+__/), path
      end
    end

    it "carries the settings of the row the site half reads", :aggregate_failures do
      membership = cms_text("auth/membership.ts")

      expect(membership).to include('DEFAULT_COOKIE = "club_session"', 'process.env["CLUB_DOMAIN_SERVICE_URL"]',
                                    'DEFAULT_URL = "http://127.0.0.1:4500"', 'ADMIN_ROLES = ["Admin", "Owner"]',
                                    '"/accounts/me"', '"/members"')
      expect(cms_text("endpoints/sso.ts")).to include('path: "/sso"', 'startsWith("/cms/")', '"/cms/admin"')
    end

    it "follows a different base path for the content system" do
      dir = edited_members do |text|
        text.sub('host_default: "http://127.0.0.1:4500",',
                 'host_default: "http://127.0.0.1:4500", cms_base: "/studio", sso_target: "/studio/api/login",')
      end

      expect(cms_text("endpoints/sso.ts", dir)).to include('path: "/login"', 'startsWith("/studio/")', '"/studio/admin"')
    end

    it "is refused when the hand-off target is outside the content system's API" do
      dir = edited_members { |text| text.sub('host_default: "http://127.0.0.1:4500",', 'host_default: "http://127.0.0.1:4500", sso_target: "/api/sso",') }

      expect(refusal(dir)).to include("Admin sso_target /api/sso must be under /cms/api/")
    end

    it "is refused when --cms is named by a project with no admin row", :aggregate_failures do
      message = nil
      expect { tool.projection(studio, cms: "/work/cms") }.to raise_error(SystemExit) { |error| message = error.message }
        .and output.to_stderr

      expect(message).to include("--cms names /work/cms, but the project declares no Admin row")
    end

    it "is written as TypeScript Node can read" do
      next skip "node is not installed" unless node?

      texts = paths.to_h { |path| [path, cms_text(path)] }
      expect(node_failures(texts, "--experimental-strip-types")).to be_empty
    end
  end

  describe "the files at the project's root" do
    def root_for_domain = members

    def root_files(project = members)
      tool.projection(project, out: "/work/out", root_dir: root_for_domain).transform_keys do |path|
        path.sub(root_for_domain, "/work/root")
      end
    end

    # The `.env.tpl` of a project whose secrets are grouped, one is commented out and one has no section.
    def grouped_env
      dir = edited_members do |text|
        text.sub(', section: "local"', "")
            .sub('member name: "PAYLOAD_SECRET"', 'member name: "PAYLOAD_SECRET", group: "Content system"')
            .sub('value: "file:./club-cms.db"', 'value: "file:./club-cms.db", off: true')
      end
      tool.projection(dir, out: "/work/out", root_dir: root_for_domain).fetch(File.join(root_for_domain, ".env.tpl"))
    end

    # The workflow of a project whose row names a yarn install.
    def yarn_workflow
      dir = edited_members do |text|
        text.sub('test: "npm run check"', 'test: "npm run check", install: "yarn install --immutable"')
      end
      tool.projection(dir, out: "/work/out", root_dir: root_for_domain)
          .fetch(File.join(root_for_domain, ".github/workflows/site-routes.yml"))
    end

    let(:names) do
      %w[.env.tpl .github/workflows/site-routes.yml cms/Dockerfile cms/deploy-aws/boot.mjs
         cms/src/generated/driver/lifecycle.ts cms/src/generated/driver/specs.ts cms/src/generated/collections/fields.ts]
    end

    it "is every file the rows declare, under the directory --root names" do
      expect(root_files.keys.grep(%r{\A/work/root/})).to match_array(names.map { |name| "/work/root/#{name}" })
    end

    it "is not written unless --root is named" do
      expect(projected.keys.grep(%r{/root/})).to be_empty
    end

    it "equals the committed goldens, byte for byte" do
      names.each do |name|
        text = root_files.fetch("/work/root/#{name}")
        expect(text).to eq(golden_for(File.join(expected, "root", name), text)), name
      end
    end

    it "holds secrets as references and never as values", :aggregate_failures do
      env = root_files.fetch("/work/root/.env.tpl")

      expect(env).to include("SESSION_SECRET=op://Club/club-site/local/SESSION_SECRET", "HECKS_SESSION_COOKIE=club_session")
      expect(env).not_to match(/SESSION_SECRET=[^o]/)
    end

    it "groups the lines, comments out those marked off, and takes a reference without a section" do
      expect(grouped_env).to include("SESSION_SECRET=op://Club/club-site/SESSION_SECRET",
                                     "\n\n# Content system\nPAYLOAD_SECRET=op://Club/club-site/PAYLOAD_SECRET",
                                     "# DATABASE_URI=file:./club-cms.db")
    end

    it "watches the files the rows name, and runs the project's own script and test" do
      workflow = root_files.fetch("/work/root/.github/workflows/site-routes.yml")

      expect(workflow).to include('- "site-routes/**"', '- "club/Gemfile.lock"', "run: bin/site_routes --check",
                                  "run: npm run check")
    end

    it "starts the content system after resolving its secrets, the extra ones too", :aggregate_failures do
      boot = root_files.fetch("/work/root/cms/deploy-aws/boot.mjs")

      expect(boot).to include('process.env["AUTH_SECRET"] = await secretField(process.env["AUTH_SECRET_ARN"], "session_secret")',
                              'process.env["ANALYTICS_KEY_JSON"] = SecretString', 'await import("./server.js")')
      expect(boot.index("PAYLOAD_SECRET_ARN")).to be < boot.index('await import("./server.js")')
    end

    it "logs in to the database as the user and port the secret names, postgres on 5432 when it names none" do
      boot = root_files.fetch("/work/root/cms/deploy-aws/boot.mjs")
      user_and_port = 'const { username = "postgres", password, port = 5432 } = await secretJson(process.env.DB_SECRET_ARN)'
      url = "${encodeURIComponent(username)}:${encodeURIComponent(password)}@${DB_HOST}:${port}/${DB_NAME}"

      expect(boot).to include(user_and_port).and include(url)
    end

    it "builds an image from the row's node version, port and heap", :aggregate_failures do
      image = root_files.fetch("/work/root/cms/Dockerfile")

      expect(image).to include("FROM node:22-slim AS build", "--max-old-space-size=768", "ENV PORT=8080",
                               'CMD ["node", "boot.mjs"]')
      expect(image).not_to match(/%<|__[A-Z]+__/)
    end

    it "writes the driver and the field definitions as TypeScript Node can read" do
      next skip "node is not installed" unless node?

      texts = names.grep(%r{cms/src/generated}).to_h { |name| [name, root_files.fetch("/work/root/#{name}")] }
      expect(node_failures(texts, "--experimental-strip-types")).to be_empty
    end

    it "leaves the image to the project when the row says dockerfile: false" do
      dir = edited_members_sub("member heap_mb: 768", "member heap_mb: 768, dockerfile: false")
      files = tool.projection(dir, out: "/work/out", root_dir: root_for_domain)

      kept = files.keys.grep(%r{cms/(Dockerfile|deploy-aws)}).map { |path| path.split("/cms/").last }
      expect(kept).to eq(["deploy-aws/boot.mjs"])
    end

    it "writes the script as JavaScript Node can read" do
      next skip "node is not installed" unless node?

      boot = root_files.fetch("/work/root/cms/deploy-aws/boot.mjs")
      expect(node_failures({ "boot.mjs" => boot })).to be_empty
    end

    it "drives the aggregates that have a lifecycle, and leaves the others alone", :aggregate_failures do
      specs = root_files.fetch("/work/root/cms/src/generated/driver/specs.ts")

      expect(specs).to include("export const meetingSpec", "export const noticeSpec", 'aggregate: "Club::Meeting"')
      expect(specs).not_to include("Settings")
    end

    it "takes the creating command, the first status and the edges from the bluebook" do
      specs = root_files.fetch("/work/root/cms/src/generated/driver/specs.ts")

      expect(specs).to include('create: { verb: "Draft", status: "draft" }', 'create: { verb: "Post", status: "posted" }',
                               'draft: { Publish: "published" }', 'published: { Withdraw: "withdrawn", Cancel: "cancelled" }')
    end

    it "acts as the role the commands declare" do
      expect(root_files.fetch("/work/root/cms/src/generated/driver/lifecycle.ts")).to include('const ROLE = "Editor"')
    end

    it "carries an integer as a number and a composite as a list of its parts" do
      specs = root_files.fetch("/work/root/cms/src/generated/driver/specs.ts")

      expect(specs).to include("postedOn: number;", "agenda: AgendaItem[];", 'whole(s.posted_on, "value")',
                               "join_link: { url: input.joinLink }")
    end

    it "reads an editor's save back with the kinds the rows name" do
      fields = root_files.fetch("/work/root/cms/src/generated/collections/fields.ts")

      day = 'postedDate: { name: "postedDate", type: "date", required: true, admin: { date: { pickerAppearance: "dayOnly" } } }'
      expect(fields).to include(day,
                                'related(req, "media", doc.cover, "url")', "Math.floor((doc.postedDate")
    end

    it "is refused when a field row names an aggregate that is not driven" do
      dir = edited_members do |text|
        text.sub('member aggregate: "Notice", attribute: "summary"', 'member aggregate: "Settings", attribute: "key"')
      end

      expect(refusal(dir,
                     root_dir: root_for_domain)).to include("PayloadField names Settings, which it does not drive")
    end

    it "is refused when an upload names no collection" do
      dir = edited_members { |text| text.sub('kind: "upload", relation: "media"', 'kind: "upload"') }

      expect(refusal(dir, root_dir: root_for_domain)).to include("is upload and needs a relation")
    end

    it "is refused when the domain has no such chapter" do
      dir = edited_members { |text| text.sub('chapter: "Club"', 'chapter: "Elsewhere"') }

      expect(refusal(dir, root_dir: root_for_domain)).to include("declares no chapter Elsewhere")
    end

    it "installs with the command the row names, enabling corepack first for yarn", :aggregate_failures do
      workflow = yarn_workflow

      expect(workflow).to include("run: corepack enable", "run: yarn install --immutable")
      steps = YAML.safe_load(workflow).dig("jobs", "routes-current-and-parity", "steps")
      expect(steps.map { |step| step["name"] }.compact).to include("Enable corepack", "Install dependencies")
      expect(workflow.index("corepack enable")).to be < workflow.index("yarn install")
    end

    it "is refused when a secret has no Secrets row to name its vault" do
      dir = edited_members { |text| text.sub(/    value_object "Secrets" do.*?\n    end\n\n/m, "") }

      expect(refusal(dir, root_dir: "/work/root")).to include("declares no Secrets row")
    end

    it "is refused when a row has a field it does not know" do
      dir = edited_members { |text| text.sub('member gem_dir: "club",', 'member gem_dir: "club", ruby_version: "3.3",') }
      text = refusal(dir, root_dir: "/work/root")

      expect(text).to include("Ci row 1 has no field ruby_version")
    end
  end

  describe "the generated module, run by node" do
    # Node strips TypeScript types from a .ts file it loads, so the modules are run as they stand.
    def run_node(script)
      Dir.mktmpdir("admin_ts") do |dir|
        projected.slice("/work/out/routes.ts", "/work/out/admin.ts").each do |path, text|
          File.write(File.join(dir, File.basename(path)), text)
        end
        File.write(File.join(dir, "check.mjs"), "#{ADMIN_NODE_PRELUDE}#{script}")
        out, err, status = Open3.capture3({ "NODE_NO_WARNINGS" => "1" }, "node", File.join(dir, "check.mjs"))
        [out, status, err]
      end
    end

    def answers(script)
      skip "node is not installed" unless node?

      out, status, err = run_node(script)
      expect(status.success?).to be(true), err
      JSON.parse(out)
    end

    it "lets a visitor reach public pages and the login page, and sends admin paths to the login page", :aggregate_failures do
      result = answers(ADMIN_NODE_VISITOR_SCRIPT)

      expect(result).to include(ADMIN_NODE_VISITOR_VERDICTS)
      expect(result["asked"]).to eq([])
    end

    it "reads a literal page as more specific than a generic one, and lets an equal tie go to admin" do
      expect(answers(ADMIN_NODE_SPECIFICITY_SCRIPT)).to eq(ADMIN_NODE_SPECIFICITY_VERDICTS)
    end

    it "lets an active admin through and turns away a member, a disabled admin and a refused cookie" do
      result = answers(ADMIN_NODE_ROLES_SCRIPT)

      expect(result).to eq("admin" => true, "owner" => true, "member" => false, "disabled" => false, "refused" => false)
    end

    it "asks the host with the declared cookie, and the environment's address when none is configured" do
      result = answers(ADMIN_NODE_ENVIRONMENT_SCRIPT)

      expect(result).to eq("email" => "a@example.org",
                           "asked" => ["/accounts/me club_session=abc", "/members club_session=abc"])
    end

    it "remembers a verdict for the TTL, shares a read in flight, and forgets on request" do
      expect(answers(ADMIN_NODE_TTL_SCRIPT)).to eq("remembered" => 2, "afterForget" => 4)
    end

    it "never remembers a failed read" do
      expect(answers(ADMIN_NODE_FAILED_READ_SCRIPT)).to eq("first" => nil, "second" => "a@example.org")
    end

    it "hands a signed-in person to the CMS with a token, and otherwise to the login page" do
      result = answers(ADMIN_NODE_SSO_SCRIPT)

      expect(result).to eq("signed" => ["/cms/api/sso?token=t+o+k", "/cms/api/sso?token=t+o+k&to=%2Fcms%2Fadmin%2Fposts"],
                           "none" => "/admin-login", "refused" => "/admin-login")
    end
  end
end

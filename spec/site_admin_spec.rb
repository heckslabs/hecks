require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "hecks/tools"
require "hecks/tools/site_routes"

# The admin sign-in module a project gets when its chapter declares an `Admin` row. The sample is
# spec/fixtures/site/members; its golden sits in spec/fixtures/site/members/expected
# (`GOLDEN=rewrite` regenerates it, to be read in the diff).
RSpec.describe "the admin sign-in module" do
  let(:tool)     { Hecks::Tools::SiteRoutes }
  let(:members)  { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/members") }
  let(:studio)   { File.join(InMemoryDomain::ROOT, "spec/fixtures/site/studio") }
  let(:expected) { File.join(members, "expected") }
  let(:work)     { Dir.mktmpdir("site_admin") }

  after { FileUtils.rm_rf(work) }

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

  def refusal(project)
    message = nil
    expect { tool.projection(project) }.to raise_error(SystemExit) { |error| message = error.message }
                                       .and output.to_stderr
    message
  end

  describe "the projection" do
    it "equals the committed golden, byte for byte" do
      golden = File.join(expected, "admin.ts")
      if ENV["GOLDEN"] == "rewrite"
        FileUtils.mkdir_p(expected)
        File.write(golden, admin_ts)
      end

      expect(admin_ts).to eq(File.read(golden))
    end

    it "is the same text every time" do
      first = admin_ts

      expect(admin_ts).to eq(first)
    end

    it "is written beside the route table, with the extension the tool is given" do
      files = projected(extension: "mts")

      expect(files.keys).to contain_exactly("/work/out/routes.mts", "/work/out/admin.mts")
      expect(files.fetch("/work/out/admin.mts")).to include('from "./routes.mts"')
    end

    it "is not written by a project that declares no admin row" do
      expect(projected(studio).keys).to eq(["/work/out/routes.ts", "/work/out/deploy/template.yaml"])
    end

    it "fills what the row leaves out" do
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

      message = refusal(dir)
      expect(message).to include("Admin sso /api/cms-sso is public; it must be admin")
      expect(message).to include("it must be an endpoint")
    end

    it "is refused for a field it does not have, and for a missing required one" do
      dir = edited_members do |text|
        text.sub('sso: "/api/cms-sso",', 'sso: "/api/cms-sso", colour: "red",').sub('session_cookie: "club_session", ', "")
      end

      message = refusal(dir)
      expect(message).to include("Admin row has no field colour")
      expect(message).to include("Admin row needs session_cookie")
    end

    it "is refused for a path with no leading slash, and for no roles" do
      dir = edited_members { |text| text.sub('roles: "Admin,Owner"', 'roles: " , "') }
      expect(refusal(dir)).to include("Admin roles name no role")

      dir = edited_members { |text| text.sub('host_default: "http://127.0.0.1:4500"', 'host_default: "http://127.0.0.1:4500", account_path: "accounts/me"') }
      expect(refusal(dir)).to include('Admin account_path "accounts/me" must start with a slash')
    end
  end

  describe "the generated module, run by node" do
    def node? = system("node", "--version", out: File::NULL, err: File::NULL)

    def host_url = "http://host.test"

    # Node strips TypeScript types from a .ts file it loads, so the modules are run as they stand.
    # The script gets `admin`, and `host(handlers)`, which builds a fake fetch and a list of what
    # it was asked.
    def run_node(script)
      Dir.mktmpdir("admin_ts") do |dir|
        files = projected
        File.write(File.join(dir, "routes.ts"), files.fetch("/work/out/routes.ts"))
        File.write(File.join(dir, "admin.ts"), files.fetch("/work/out/admin.ts"))
        File.write(File.join(dir, "check.mjs"), <<~JS)
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
          #{script}
        JS
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

    it "lets a visitor reach public pages and the login page, and sends admin paths to the login page" do
      result = answers(<<~JS)
        const none = host({});
        admin.configureAdmin({ host: "#{host_url}", fetch: none.fetch });
        const gate = (path) => admin.adminGate(path, undefined);
        console.log(JSON.stringify({
          home: await gate("/"), events: await gate("/events"), login: await gate("/admin-login"),
          loginHtml: await gate("/admin-login.html"), admin: await gate("/admin"), inbox: await gate("/admin-inbox"),
          cms: await gate("/cms/admin"), sso: await gate("/api/cms-sso"), preview: await gate("/admin-preview/events"),
          asked: none.asked,
        }));
      JS

      expect(result).to include(
        "home" => { "allow" => true }, "events" => { "allow" => true }, "login" => { "allow" => true },
        "loginHtml" => { "allow" => true },
        "admin" => { "allow" => false, "redirect" => "/admin-login" },
        "inbox" => { "allow" => false, "redirect" => "/admin-login" },
        "cms" => { "allow" => false, "redirect" => "/admin-login" },
        "sso" => { "allow" => false, "redirect" => "/admin-login" },
        "preview" => { "allow" => false, "status" => 401 }
      )
      expect(result["asked"]).to eq([])
    end

    it "lets an active admin through and turns away a member, a disabled admin and a refused cookie" do
      result = answers(<<~JS)
        const verdict = async (handlers) => {
          const fake = host(handlers);
          admin.configureAdmin({ host: "#{host_url}", fetch: fake.fetch });
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

      expect(result).to eq("admin" => true, "owner" => true, "member" => false, "disabled" => false, "refused" => false)
    end

    it "asks the host with the declared cookie, and the environment's address when none is configured" do
      result = answers(<<~JS)
        const fake = host(signedIn("a@example.org", "Admin", false));
        process.env.CLUB_DOMAIN_SERVICE_URL = "#{host_url}/";
        admin.configureAdmin({ fetch: fake.fetch });
        const email = await admin.currentAdminEmail("abc");
        console.log(JSON.stringify({ email, asked: fake.asked.sort() }));
      JS

      expect(result).to eq("email" => "a@example.org",
                           "asked" => ["/accounts/me club_session=abc", "/members club_session=abc"])
    end

    it "remembers a verdict for the TTL, shares a read in flight, and forgets on request" do
      result = answers(<<~JS)
        const fake = host(signedIn("a@example.org", "Admin", false));
        admin.configureAdmin({ host: "#{host_url}", fetch: fake.fetch });
        await Promise.all([admin.currentAdminEmail("abc"), admin.currentAdminEmail("abc")]);
        await admin.currentAdminEmail("abc");
        const remembered = fake.asked.length;
        admin.forgetAdminSessions();
        await admin.currentAdminEmail("abc");
        console.log(JSON.stringify({ remembered, afterForget: fake.asked.length }));
      JS

      expect(result).to eq("remembered" => 2, "afterForget" => 4)
    end

    it "never remembers a failed read" do
      result = answers(<<~JS)
        let failing = true;
        const fake = host({
          "/accounts/me": () => (failing ? [500, {}] : [200, { email: "a@example.org" }]),
          "/members": () => [200, [{ email: "a@example.org", role: "Admin" }]],
        });
        admin.configureAdmin({ host: "#{host_url}", fetch: fake.fetch });
        const first = await admin.currentAdminEmail("abc");
        failing = false;
        admin.forgetAdminSessions();
        console.log(JSON.stringify({ first, second: await admin.currentAdminEmail("abc") }));
      JS

      expect(result).to eq("first" => nil, "second" => "a@example.org")
    end

    it "hands a signed-in person to the CMS with a token, and otherwise to the login page" do
      result = answers(<<~JS)
        const ok = host({ "/accounts/sso-token": () => [200, { token: "t o k" }] });
        admin.configureAdmin({ host: "#{host_url}", fetch: ok.fetch });
        const signed = [await admin.ssoRedirect("abc"), await admin.ssoRedirect("abc", "/cms/admin/posts")];
        const none = await admin.ssoRedirect(undefined);
        admin.configureAdmin({ host: "#{host_url}", fetch: host({}).fetch });
        console.log(JSON.stringify({ signed, none, refused: await admin.ssoRedirect("abc") }));
      JS

      expect(result).to eq("signed" => ["/cms/api/sso?token=t+o+k", "/cms/api/sso?token=t+o+k&to=%2Fcms%2Fadmin%2Fposts"],
                           "none" => "/admin-login", "refused" => "/admin-login")
    end
  end
end

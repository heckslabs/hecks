require "hecks/projections/deploy/box"

# The `deployed_to("AwsBox")` settings, checked before any file is generated. `Settings.resolve` is what
# `Box.call` runs after `BoxTarget.Declare`, so a mistake in a `.world` file is refused here with the
# setting's name in the message, and nothing from a world can reach a template or a script unchecked.
RSpec.describe Hecks::Projections::Deploy::Box::Settings do
  subject(:settings) { described_class }

  Held = Struct.new(:value)
  Declared = Struct.new(:state)

  let(:target) do
    Declared.new({ instance_type: Held.new("t4g.medium"), volume_gb: Held.new(30),
                   database_class: Held.new("db.t4g.small"), storage_gb: Held.new(20) })
  end

  let(:web) { { name: "web", port: 8080 } }

  def resolve(infra_name: "shop", **given)
    settings.resolve(deploy_settings: { containers: [web] }.merge(given), target: target, infra_name: infra_name)
  end

  def refusal(**given)
    resolve(**given)
    nil
  rescue ArgumentError => e
    e.message
  end

  describe "with only a container" do
    it "resolves to the defaults the golden stack is built from" do
      plan = resolve

      expect(plan).to have_attributes(
        infra_name: "shop", stack_prefix: "hecks", instance_type: "t4g.medium", volume_gb: 30, swap_gb: 2,
        database_class: "db.t4g.small", storage_gb: 20, backup_days: 7, snapshots_keep: 7, database_name: "shop",
        engine_version: "16", default_container: "web", origin_header: nil, origin_secret: nil,
        secret_prefixes: ["shop/*"], tunnel: false, routes: []
      )
      expect(plan.rds_stack).to eq("hecks-shop-rds")
      expect(plan.box_stack).to eq("hecks-shop-box")
      expect(plan.containers.first).to have_attributes(name: "web", repository: "shop-web", port: 8080, env: {}, secrets: {})
    end

    it "strips non-alphanumerics from the derived database name" do
      expect(resolve(infra_name: "shop-front").database_name).to eq("shopfront")
    end
  end

  describe "containers" do
    it "is required" do
      expect(refusal(containers: nil)).to include("containers").and include("at least one container")
      expect(refusal(containers: [])).to include("at least one container")
    end

    it "refuses a duplicate name and a shared port" do
      expect(refusal(containers: [web, { name: "web", port: 9090 }])).to include('two containers are named "web"')
      expect(refusal(containers: [web, { name: "cms", port: 8080 }])).to include("two containers listen on port 8080")
    end

    it "refuses a name or repository that could not be spliced safely" do
      expect(refusal(containers: [{ name: "web; rm -rf /", port: 8080 }])).to include("container_name")
      expect(refusal(containers: [{ name: "web", port: 8080, repository: "a b" }])).to include("repository")
    end

    it "carries environment variables and named secrets, and refuses a malformed one" do
      plan = resolve(containers: [web.merge(env: { "HOST" => "0.0.0.0" }, secrets: { "AUTH" => "shop/auth" })])

      expect(plan.containers.first).to have_attributes(env: { "HOST" => "0.0.0.0" }, secrets: { "AUTH" => "shop/auth" })
      expect(refusal(containers: [web.merge(env: { "1BAD" => "x" })])).to include("env")
      expect(refusal(containers: [web.merge(env: { "A" => "line\nbreak" })])).to include("env")
      expect(refusal(containers: [web.merge(secrets: { "A" => "shop/$(id)" })])).to include("secrets")
    end

    it "refuses a port outside 1..65535" do
      expect(refusal(containers: [{ name: "web", port: 0 }])).to include("port")
      expect(refusal(containers: [{ name: "web", port: 70_000 }])).to include("port")
    end
  end

  describe "routes and the default container" do
    let(:two) { [web, { name: "cms", port: 8081 }] }

    it "needs a default container when there are several" do
      expect(refusal(containers: two)).to include("default_container")
      expect(resolve(containers: two, default_container: "web").default.name).to eq("web")
    end

    it "refuses a route to a container that is not declared, and a default that is not declared" do
      expect(refusal(containers: two, default_container: "web", routes: [{ container: "ghost", paths: ["/x/*"] }]))
        .to include('"ghost" is not a declared container')
      expect(refusal(containers: two, default_container: "ghost")).to include('"ghost" is not a declared container')
    end

    it "refuses a route with no paths or with a path that is not a URL path" do
      expect(refusal(containers: two, default_container: "web", routes: [{ container: "cms" }])).to include("no paths")
      expect(refusal(containers: two, default_container: "web", routes: [{ container: "cms", paths: ["cms/*"] }]))
        .to include("path")
      expect(refusal(containers: two, default_container: "web", routes: [{ container: "cms", paths: ["/a {b}"] }]))
        .to include("path")
    end

    it "keeps routes in the order the world gives them" do
      plan = resolve(containers: two, default_container: "web",
                     routes: [{ container: "cms", paths: ["/cms/*"] }, { container: "web", paths: ["/a", "/b/*"] }])

      expect(plan.routes.map(&:paths)).to eq([["/cms/*"], ["/a", "/b/*"]])
    end
  end

  describe "the origin guard" do
    it "takes a header and a secret together" do
      plan = resolve(origin_header: "X-Origin-Secret", origin_secret: "shop/origin")

      expect(plan).to have_attributes(origin_header: "X-Origin-Secret", origin_secret: "shop/origin")
      expect(refusal(origin_header: "X-Origin-Secret")).to include("go together")
      expect(refusal(origin_secret: "shop/origin")).to include("go together")
    end

    it "refuses a header with characters Caddy would read as syntax" do
      expect(refusal(origin_header: "X Origin {", origin_secret: "shop/origin")).to include("origin_header")
    end
  end

  describe "secret prefixes, tunnel and sizes" do
    it "takes a list of secret name patterns and refuses one with shell characters" do
      expect(resolve(secret_prefixes: ["a/*", "b/c"]).secret_prefixes).to eq(["a/*", "b/c"])
      expect(refusal(secret_prefixes: ["a b"])).to include("secret_prefixes")
    end

    it "takes a boolean tunnel and refuses anything else" do
      expect(resolve(tunnel: true).tunnel).to be(true)
      expect(refusal(tunnel: "yes")).to include("must be true or false")
    end

    it "bounds backup days, snapshots and swap, and checks the engine version" do
      expect(refusal(backup_days: 0)).to include("backup_days")
      expect(refusal(snapshots_keep: 0)).to include("snapshots_keep")
      expect(refusal(swap_gb: 100)).to include("swap_gb")
      expect(refusal(engine_version: "sixteen")).to include("engine_version")
      expect(resolve(engine_version: "16.4").engine_version).to eq("16.4")
    end
  end

  describe "the stack name" do
    it "refuses a name CloudFormation would reject" do
      expect(refusal(infra_name: "Shop_Front")).to include("stack_name")
    end
  end
end

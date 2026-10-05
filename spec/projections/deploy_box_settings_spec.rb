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

    it "takes a boolean tunnel, which opens the egress and runs no service" do
      plan = resolve(tunnel: true)

      expect(plan.tunnel).to be(true)
      expect(plan.tunnel_service).to be_nil
      expect(resolve.tunnel_service).to be_nil
      expect(refusal(tunnel: "yes")).to include("must be true or false")
    end

    describe "a tunnel service" do
      let(:two) { [web, { name: "stats", port: 3000 }] }

      it "forwards to the named container's port and reads its token from a secret" do
        plan = resolve(containers: two, default_container: "web", tunnel: { to: "stats", token_secret: "shop/tunnel" })

        expect(plan.tunnel).to be(true)
        expect(plan.tunnel_service).to have_attributes(container: "stats", port: 3000, token_secret: "shop/tunnel",
                                                       image: described_class::TUNNEL_IMAGE)
      end

      it "takes an image of its own" do
        plan = resolve(tunnel: { to: "web", token_secret: "shop/tunnel", image: "cloudflare/cloudflared:2026.9.0" })

        expect(plan.tunnel_service.image).to eq("cloudflare/cloudflared:2026.9.0")
      end

      it "refuses a missing half, an unknown container and an image that could not be spliced safely" do
        expect(refusal(tunnel: { to: "web" })).to include("token_secret")
        expect(refusal(tunnel: { token_secret: "shop/tunnel" })).to include("`to`")
        expect(refusal(tunnel: { to: "ghost", token_secret: "shop/tunnel" })).to include('"ghost" is not a declared container')
        expect(refusal(tunnel: { to: "web", token_secret: "shop/tunnel", image: "x; rm -rf /" })).to include("tunnel_image")
      end
    end

    it "bounds backup days, snapshots and swap, and checks the engine version" do
      expect(refusal(backup_days: 0)).to include("backup_days")
      expect(refusal(snapshots_keep: 0)).to include("snapshots_keep")
      expect(refusal(swap_gb: 100)).to include("swap_gb")
      expect(refusal(engine_version: "sixteen")).to include("engine_version")
      expect(resolve(engine_version: "16.4").engine_version).to eq("16.4")
    end
  end

  describe "a task definition" do
    it "is nil unless the world names one" do
      expect(resolve.task_definition).to be_nil
      expect(resolve(task_definition: "shop-platform").task_definition).to eq("shop-platform")
    end

    it "refuses a family that could not be spliced safely" do
      expect(refusal(task_definition: "shop platform")).to include("task_definition")
      expect(refusal(task_definition: "shop-platform:7")).to include("task_definition")
    end

    it "refuses a container that also sets what the task definition supplies" do
      with_env = [web.merge(env: { "A" => "1" })]
      with_both = [web.merge(secrets: { "A" => "shop/a" }, repository: "shop-web")]

      expect(refusal(task_definition: "shop-platform", containers: with_env))
        .to include("web sets env", "shop-platform supplies")
      expect(refusal(task_definition: "shop-platform", containers: with_both)).to include("secrets, repository")
      expect(resolve(containers: with_env).containers.first.env).to eq("A" => "1")
    end
  end

  describe "s3 access" do
    it "is empty unless the world declares buckets" do
      expect(resolve.s3_buckets).to eq([])
    end

    it "reads each bucket, and writes only where the world says so, once per name" do
      plan = resolve(s3_access: [{ bucket: "media", write: true }, { bucket: "assets" }, { bucket: "media" }])

      expect(plan.s3_buckets.map(&:to_h)).to eq([{ name: "media", write: true }, { name: "assets", write: false }])
    end

    it "refuses a bucket name that could not be spliced safely, a missing name and a write that is not a boolean" do
      expect(refusal(s3_access: [{ bucket: "Bad Bucket" }])).to include("s3_bucket")
      expect(refusal(s3_access: [{ bucket: "a/../b" }])).to include("s3_bucket")
      expect(refusal(s3_access: [{ write: true }])).to include("s3_access")
      expect(refusal(s3_access: [{ bucket: "media", write: "yes" }])).to include("s3_write")
      expect(refusal(s3_access: "media")).to include("s3_access")
    end
  end

  describe "a migration" do
    it "is nil unless the world declares one" do
      expect(resolve.migration).to be_nil
    end

    it "copies the named schemas, defaulting both databases to the RDS one" do
      plan = resolve(database_name: "shopdb", migration: { schemas: %w[a a_cms a] })

      expect(plan.migration).to have_attributes(schemas: %w[a a_cms], database: "shopdb", source_database: "shopdb")
    end

    it "takes a database on each side" do
      plan = resolve(migration: { schemas: ["a"], database: "newdb", source_database: "olddb" })

      expect(plan.migration).to have_attributes(database: "newdb", source_database: "olddb")
    end

    it "refuses a migration with no schemas, a schema that could not be spliced safely, or a bad database" do
      expect(refusal(migration: {})).to include("`schemas`")
      expect(refusal(migration: { schemas: [] })).to include("`schemas`")
      expect(refusal(migration: "a")).to include("`schemas`")
      expect(refusal(migration: { schemas: ["a; drop schema b"] })).to include("migration_schemas")
      expect(refusal(migration: { schemas: ["Upper"] })).to include("migration_schemas")
      expect(refusal(migration: { schemas: ["a"], source_database: "old db" })).to include("migration_source_database")
    end
  end

  describe "images" do
    it "pins both default images by version and digest" do
      expect(described_class::TUNNEL_IMAGE).to match(%r{\Acloudflare/cloudflared:\d+\.\d+\.\d+@sha256:\h{64}\z})
      expect(described_class::PROXY_IMAGE).to match(%r{\Apublic\.ecr\.aws/docker/library/caddy:\d+\.\d+@sha256:\h{64}\z})
      expect(resolve.proxy_image).to eq(described_class::PROXY_IMAGE)
    end

    it "takes a proxy image of its own and refuses one that could not be spliced safely" do
      expect(resolve(proxy_image: "caddy:2.9").proxy_image).to eq("caddy:2.9")
      expect(refusal(proxy_image: "caddy 2.9")).to include("proxy_image")
    end
  end

  describe "hosting scripts" do
    let(:hosting) { { hosting_scripts: true, smoke_workflow: "smoke.yml" } }

    it "are off unless the world opts in" do
      expect(resolve.hosting).to be_nil
      expect(resolve(hosting_scripts: false).hosting).to be_nil
    end

    it "resolve to the smoke defaults and a parameter name per container" do
      plan = resolve(**hosting)

      expect(plan.hosting).to have_attributes(stack: nil, smoke_repo: nil, smoke_workflow: "smoke.yml",
                                              smoke_ref: "main", expected_eras: [], public_url: nil)
      expect(plan.containers.first.tag_parameter).to eq("WebImageTag")
    end

    it "name the parameter after a dashed container, or take the one the world gives" do
      listed = [{ name: "web-app", port: 80 }, { name: "cms", port: 81, tag_parameter: "CmsTag" }]
      plan = resolve(containers: listed, default_container: "web-app")

      expect(plan.containers.map(&:tag_parameter)).to eq(%w[WebAppImageTag CmsTag])
      expect(refusal(containers: [{ name: "cms", port: 81, tag_parameter: "Cms Tag" }])).to include("tag_parameter")
    end

    it "refuse a world that names no smoke workflow" do
      expect(refusal(hosting_scripts: true)).to include("smoke_workflow")
    end

    it "refuse a flag that is not true or false, and a workflow that is not a file name" do
      expect(refusal(hosting_scripts: "yes", smoke_workflow: "smoke.yml")).to include("hosting_scripts")
      expect(refusal(hosting_scripts: true, smoke_workflow: "smoke; rm -rf /")).to include("smoke_workflow")
      expect(refusal(hosting_scripts: true, smoke_workflow: "smoke.yml", smoke_repo: "not a repo")).to include("smoke_repo")
      expect(refusal(hosting_scripts: true, smoke_workflow: "smoke.yml", smoke_ref: "main; x")).to include("smoke_ref")
      expect(refusal(**hosting, expected_eras: ["a b"])).to include("expected_eras")
      expect(refusal(**hosting, public_url: "javascript:x")).to include("public_url")
    end

    it "refuse a hosting word when the scripts are not on" do
      expect(refusal(smoke_workflow: "smoke.yml")).to include("only apply with hosting_scripts true")
      expect(refusal(hosting_scripts: false, expected_eras: ["a"])).to include("expected_eras")
    end

    it "need the stack behind a task definition, and refuse a stack when there is none" do
      with_task = { **hosting, task_definition: "shop-platform" }

      expect(refusal(**with_task)).to include("hosting_stack")
      expect(resolve(**with_task, hosting_stack: "shop-platform").hosting.stack).to eq("shop-platform")
      expect(refusal(**with_task, hosting_stack: "bad stack")).to include("hosting_stack")
      expect(refusal(**hosting, hosting_stack: "shop-platform")).to include("this world has none")
    end
  end

  describe "the stack name" do
    it "refuses a name CloudFormation would reject" do
      expect(refusal(infra_name: "Shop_Front")).to include("stack_name")
    end
  end
end

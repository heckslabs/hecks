require "hecks/projections/deploy/fargate"

# The optional `deployed_to("AwsFargate")` settings, checked before any file is generated.
# `Settings.resolve` is what `Fargate.call` runs first, so a mistake in a `.world` file is
# refused here with the setting's name in the message, not found later as a broken template.
RSpec.describe Hecks::Projections::Deploy::Fargate::Settings do
  subject(:settings) { described_class }

  let(:base) do
    { infra_name: "widget", logical_id: "WidgetService", db_id: "WidgetDb", stack_name: "hecks-widget", port: 8080,
shared: false }
  end

  def resolve(given = {}) = settings.resolve(given, base)

  def refusal(given) = attempt(given, false)

  def refusal_shared(given) = attempt(given, true)

  def attempt(given, shared)
    settings.resolve(given, base.merge(shared: shared))
    nil
  rescue ArgumentError => e
    e.message
  end

  describe "with no optional setting" do
    it "resolves to the derived ids, the derived names and one container" do
      plan = resolve

      expect(plan.ids[:service]).to eq("WidgetService")
      expect(plan.ids[:alb]).to eq("WidgetServiceAlb")
      expect(plan.ids[:database_prefix]).to eq("WidgetDb")
      expect(plan.names).to include(cluster: "hecks-widget", log_group: "/ecs/hecks-widget", alb: "hecks-widget-alb",
                                    family: "widget")
      expect(plan.layout.all.map(&:name)).to eq(["widget"])
      expect(plan.layout.domain.tag_parameter).to eq("ImageTag")
      expect(plan.cdn).to be_nil
      expect(plan.alerts).to be_nil
    end
  end

  describe "logical_ids and names" do
    it "replaces a derived id and keeps the rest" do
      plan = resolve(logical_ids: { alb: "Alb", cluster: "Cluster" })

      expect(plan.ids.values_at(:alb, :cluster, :listener)).to eq(["Alb", "Cluster", "WidgetServiceListener"])
    end

    it "refuses an unknown role and an id CloudFormation would not accept" do
      expect(refusal(logical_ids: { balancer: "Alb" })).to include("unknown key(s) balancer")
      expect(refusal(logical_ids: { alb: "my-alb" })).to include("logical_ids alb must be a CloudFormation logical id")
    end

    it "refuses a description EC2 would reject" do
      expect(refusal(names: { alb_security_group_description: "café" })).to include("printable ASCII")
    end
  end

  describe "containers and routes" do
    let(:containers) do
      [{ name: "site", repository: "widget-site", port: 3000 },
       { name: "admin", repository: "widget-admin", port: 3001, health_path: "/admin/up" }]
    end

    it "gives every added container its own repository id, tag parameter and target group" do
      routes = [{ container: "admin", paths: ["/admin/*"], priority: 5 }, { container: "widget", paths: ["/api/*"], priority: 6 }]
      plan = resolve(containers: containers, default_container: "site", routes: routes)
      admin = plan.layout.extras.last

      expect([admin.repository_id, admin.tag_parameter,
              admin.target_group_id]).to eq(["AdminRepository", "AdminImageTag", "AdminTargetGroup"])
      expect(plan.layout.default.name).to eq("site")
      expect(plan.layout.routes.map(&:id)).to eq(["ListenerRuleAdmin", "ListenerRuleWidget"])
    end

    it "numbers the second rule that targets one container" do
      routes = [{ container: "admin", paths: ["/a/*"], priority: 1 }, { container: "admin", paths: ["/b/*"], priority: 2 },
                { container: "widget", paths: ["/c/*"], priority: 3 }]

      ids = resolve(containers: containers, default_container: "site", routes: routes).layout.routes.map(&:id)

      expect(ids).to eq(%w[ListenerRuleAdmin ListenerRuleAdmin2 ListenerRuleWidget])
    end

    it "refuses a container that the load balancer could never reach" do
      expect(refusal(containers: containers)).to include("container(s) site, admin have a port but no route")
    end

    it "refuses two containers on one port, since a task shares one network namespace" do
      clash = [{ name: "site", repository: "widget-site", port: 8080 }]

      expect(refusal({ containers: clash, default_container: "site" })).to include("container ports must be unique")
    end

    it "refuses a route to a container that does not exist or has no port" do
      routes = [{ container: "missing", paths: ["/x"], priority: 1 }]
      sidecar = [{ name: "logs", repository: "widget-logs" }]

      expect(refusal(containers: containers, default_container: "site", routes: routes)).to include("not a container with a port")
      expect(refusal(containers: sidecar,
                     routes:     [{ container: "logs", paths: ["/x"],
priority: 1 }])).to include("not a container with a port")
    end

    it "refuses more than five paths in one rule, a repeated priority and a path that is not a pattern" do
      many = { container: "admin", paths: %w[/a /b /c /d /e /f], priority: 1 }
      twice = [{ container: "admin", paths: ["/a"], priority: 1 }, { container: "widget", paths: ["/b"], priority: 1 }]
      bare = { container: "admin", paths: ["admin"], priority: 1 }
      given = { containers: containers, default_container: "site" }

      expect(refusal(given.merge(routes: [many]))).to include("takes at most 5 entries")
      expect(refusal(given.merge(routes: twice))).to include("route priorities must be unique")
      expect(refusal(given.merge(routes: [bare]))).to include("must start with / or *")
    end

    it "refuses an unknown container key, so a misspelling is not silently ignored" do
      expect(refusal(containers: [{ name: "site", repository: "r", prot: 3000 }])).to include("unknown key(s) prot")
    end

    it "lets a container without a port ride along in the task" do
      plan = resolve(containers: [{ name: "logs", repository: "widget-logs", env: { "LEVEL" => "info" } }])

      expect(plan.layout.balanced.map(&:name)).to eq(["widget"])
      expect(plan.layout.extras.first.port).to be_nil
    end
  end

  describe "cdn" do
    it "checks aliases, the certificate, policies and behavior origins" do
      expect(refusal(cdn: { aliases: ["www.example.com"] })).to include("need a certificate_arn")
      expect(refusal(cdn: { aliases: ["not a host"], certificate_arn: "!Ref Cert" })).to include("must be hostnames")
      expect(refusal(cdn: { certificate_arn: "arn:aws:acm:eu-west-1:123456789012:certificate/abc" })).to include("us-east-1")
      expect(refusal(cdn: { behaviors: [{ path: "/x", cache_policy: "fast" }] })).to include("cache_policy must be")
      expect(refusal(cdn: { behaviors: [{ path: "/x", origin: "Nowhere" }] })).to include("origin \"Nowhere\" is not one of")
      expect(refusal(cdn: { behaviors: [{ path: "x" }] })).to include("path must start with / or *")
    end

    it "matches a behavior's default origin request policy to its origin" do
      cdn = resolve(cdn: {
                      extra_origins: [{ id: "Assets", domain_name: "assets.example.com" }],
                      behaviors:     [{ path: "/a/*" }, { path: "/v/*", origin: "Assets" }]
                    }).cdn

      expect(cdn[:behaviors].map { |b| b[:origin_request_policy]&.last }).to eq(["Managed-AllViewer", nil])
    end
  end

  describe "alerts" do
    it "needs a topic and rejects a malformed address, an unknown kind and an unknown container" do
      expect(refusal(alerts: { email: "ops@example.com" })).to include("alerts needs topic")
      expect(refusal(alerts: { topic: "t", email: "ops" })).to include("email address")
      expect(refusal(alerts: { topic: "t", alarms: ["disk_full"] })).to include("kind must be one of")
      expect(refusal(alerts: { topic:  "t",
                               alarms: [{ kind: "target_unhealthy", container: "nope" }] })).to include("has no target group")
    end

    it "expands target_unhealthy to one alarm per load-balanced container" do
      plan = resolve(alerts: { topic: "t", alarms: ["target_unhealthy"] })

      expect(plan.alerts[:alarms].map { |alarm| alarm[:container] }).to eq(["widget"])
    end

    it "needs cdn options when an alarm reads CloudFront metrics" do
      expect(refusal(alerts: { topic: "t", alarms: ["cloudfront_5xx"] })).to include("needs cdn options")
      expect(refusal({ alerts: { topic: "t", alarms: ["cloudfront_5xx"] }, cdn: {} })).to be_nil
    end

    it "checks the warmer's paths and schedule" do
      expect(refusal(alerts: { topic: "t", warmer: { paths: ["home"] } })).to include("must start with /")
      expect(refusal(alerts: { topic: "t", warmer: { paths: ["/"], rate: "often" } })).to include("schedule expression")
    end
  end

  describe "service tuning and the remaining settings" do
    it "reads the tuning settings" do
      plan = resolve(execute_command: true, health_check_grace_period: 10, deregistration_delay: 30,
                     desired_count_parameter: "DesiredCount")

      expect([plan.execute_command, plan.health_check_grace_period, plan.deregistration_delay,
              plan.desired_count_parameter]).to eq([true, 10, 30, "DesiredCount"])
    end

    it "refuses out-of-range and mistyped values" do
      expect(refusal(deregistration_delay: 4000)).to include("deregistration_delay must be a whole number from 0 to 3600")
      expect(refusal(execute_command: "yes")).to include("execute_command must be true or false")
      expect(refusal(install_dir: "app")).to include("absolute path")
      expect(refusal(build_context_dir: "build")).to include("ending in /")
    end

    it "keeps the database grant on the execution role unless another policy takes its place" do
      policy = [{ name: "Inject", statements: [{ actions: ["secretsmanager:GetSecretValue"], resources: ["!Ref Secret"] }] }]

      expect(refusal(execution_role_database_grant: false)).to include("without a policy")
      expect(refusal({ execution_role_database_grant: false, execution_policies: policy })).to be_nil
      expect(resolve.execution_database_grant).to be(true)
    end

    it "accepts db_name_parameter only for a shared database" do
      expect(refusal(db_name_parameter: "DbName")).to include("applies only to database \"Shared\"")
      expect(refusal_shared(db_name_parameter: "DbName")).to be_nil
    end

    it "keeps a nil domain_env value, which removes a default variable" do
      expect(resolve(domain_env: { HECKS_ERA: nil,
"SITE_URL" => "https://example.com" }).domain_env).to eq("HECKS_ERA" => nil, "SITE_URL" => "https://example.com")
    end

    it "checks buckets, secrets, policies, parameters and outputs" do
      expect(refusal(buckets: [{ id: "Media" }])).to include("needs name_prefix")
      expect(refusal(generated_secrets: [{ id: "S", name: "n", length: 2 }])).to include("length must be a whole number")
      expect(refusal(task_policies: [{ name:       "P",
                                       statements: [{ actions: [], resources: ["*"] }] }])).to include("needs at least 1 entry")
      expect(refusal(parameters: { "P" => { default: "x" } })).to include("needs type")
      expect(refusal(parameters: { "P" => { type: "Text" } })).to include("not a CloudFormation parameter type")
      expect(refusal(outputs: { "O" => nil })).to include("needs a value")
    end
  end
end

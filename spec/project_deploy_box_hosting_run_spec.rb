require_relative "support/box_hosting_stubs"

# The hosting scripts `deployed_to("AwsBox")` generates for `hosting_scripts true`, run against
# stand-in `aws`, `docker` and `gh` programs: the golden files are the input, so a script that
# parses but does the wrong thing fails here. Nothing reaches AWS or GitHub.
RSpec.describe "AwsBox hosting scripts, run", :io do
  let(:taskdef_dir) { File.join(__dir__, "fixtures", "deploy_box_golden", "hosting_taskdef") }
  let(:services_dir) { File.join(__dir__, "fixtures", "deploy_box_golden", "hosting_services") }
  let(:registry) { BoxHostingStubs::REGISTRY }

  attr_reader :runner

  # Runs every example of the group against a fresh stand-in runner over the named fixtures.
  def self.runs_against(directory)
    around do |example|
      BoxHostingStubs.with_runner(public_send(directory)) do |runner|
        @runner = runner
        example.run
      end
    end
  end

  def settled_box(runner, images)
    up = (images.keys + ["caddy"]).map { |name| "#{name} Up 3 minutes" }
    runner.box_report(compose: images, containers: up.join("\n"))
  end

  def deploy_cms
    runner.run("deploy-service.sh", "cms", env: { "SKIP_POST_DEPLOY_SMOKE" => "1" })
  end

  def redeploy_cms_with_existing_tag
    runner.parameters("WebsiteImageTag" => "website-old", "CmsImageTag" => "cms-keep",
                      "EngineImageTag" => "domain-old", "Other" => "x")
    runner.run("deploy-service.sh", "cms",
               env: { "EXISTING_TAG" => "cms-keep", "STUB_ECR_HAS_TAG" => "1", "STUB_NO_UPDATES" => "1",
                      "SKIP_POST_DEPLOY_SMOKE" => "1" })
  end

  def deploy_cms_onto_running_box
    runner.box_report(compose:    { "website" => "#{registry}/widget-shop-website:website-111",
                                    "cms"     => "#{registry}/acme-cms:cms-222" },
                      containers: "")
    deploy_cms
  end

  describe "deploy-service.sh with a task definition" do
    runs_against :taskdef_dir

    it "pushes a fresh tag and sets only that container's parameter", :aggregate_failures do
      out, err, status = deploy_cms

      expect(status.success?).to be(true), "#{out}\n#{err}"
      expect(runner.current_parameters.fetch("CmsImageTag")).to match(/\Acms-\d{14}\z/)
      expect(runner.current_parameters).to include("WebsiteImageTag" => "website-old", "Other" => "x")
    end

    it "tags and pushes the image under the fresh tag", :aggregate_failures do
      deploy_cms
      tag = runner.current_parameters.fetch("CmsImageTag")

      expect(runner.calls).to include("docker tag widget-cms:latest #{registry}/widget-cms:#{tag}")
      expect(runner.calls.grep(/docker .*push/).first).to end_with("push #{registry}/widget-cms:#{tag}")
    end

    it "rolls the revision it registered, after the stack update", :aggregate_failures do
      deploy_cms

      expect(runner.calls).to include("deploy-box widget-platform:7")
      expect(runner.calls.index { |c| c.include?("update-stack") }).to be < runner.calls.index("deploy-box widget-platform:7")
    end

    it "uses the parameter the world named for a container", :aggregate_failures do
      _out, _err, status = runner.run("deploy-service.sh", "domain", env: { "SKIP_POST_DEPLOY_SMOKE" => "1" })

      expect(status.success?).to be(true)
      expect(runner.current_parameters.fetch("EngineImageTag")).to start_with("domain-2")
    end

    it "refuses a tag that is already in ECR before pushing anything", :aggregate_failures do
      _out, err, status = runner.run("deploy-service.sh", "cms", env: { "STUB_ECR_HAS_TAG" => "1" })

      expect(status.success?).to be(false)
      expect(err).to include("a tag is never reused")
      expect(runner.calls.grep(/push/)).to be_empty
    end

    it "refuses an unknown service", :aggregate_failures do
      _out, err, status = runner.run("deploy-service.sh", "nope")

      expect(status.success?).to be(false)
      expect(err).to include("unknown service 'nope'")
    end

    it "redeploys an existing tag without pushing, and accepts a stack that already has it", :aggregate_failures do
      _out, err, status = redeploy_cms_with_existing_tag

      expect(status.success?).to be(true), err
      expect(runner.calls.grep(/push|docker tag/)).to be_empty
      expect(runner.calls).to include("deploy-box widget-platform:7")
    end

    it "refuses to roll when the stack update fails", :aggregate_failures do
      runner.stack_status("UPDATE_ROLLBACK_COMPLETE")
      _out, err, status = runner.run("deploy-service.sh", "cms")

      expect(status.success?).to be(false)
      expect(err).to include("the stack update failed")
      expect(runner.calls.grep(/deploy-box/)).to be_empty
    end
  end

  describe "deploy-service.sh without a task definition" do
    runs_against :services_dir

    it "names the new tag for the service and the tag the box runs now for every other one", :aggregate_failures do
      out, err, status = deploy_cms_onto_running_box

      expect(status.success?).to be(true), "#{out}\n#{err}"
      expect(runner.calls.grep(/\Adeploy-box/).first).to match(/\Adeploy-box website=website-111 cms=cms-\d{14}\z/)
    end

    it "leaves the stack alone and tags the image under the new tag", :aggregate_failures do
      deploy_cms_onto_running_box

      expect(runner.calls.grep(/update-stack/)).to be_empty
      expect(runner.calls).to include(a_string_matching(%r{docker tag acme-cms:latest #{registry}/acme-cms:cms-}))
    end
  end

  describe "smoke-after-deploy.sh" do
    runs_against :taskdef_dir

    let(:images) do
      { "website" => "#{registry}/widget-website:website-old", "cms" => "#{registry}/widget-cms:cms-old",
        "domain" => "#{registry}/widget-domain:domain-old" }
    end

    it "dispatches the smoke and reports its conclusion once the box runs the task definition's images", :aggregate_failures do
      settled_box(runner, images)
      out, err, status = runner.run("smoke-after-deploy.sh")

      expect(status.exitstatus).to eq(0), "#{out}\n#{err}"
      expect(out).to include("two consecutive checks agree", "post-deploy smoke passed")
      expect(runner.calls).to include("gh workflow run smoke-prod.yml --repo acme/widget-shop --ref main")
    end

    it "does not dispatch while the box runs a different image than the task definition names (exit 20)", :aggregate_failures do
      settled_box(runner, images.merge("cms" => "#{registry}/widget-cms:cms-stale"))
      out, _err, status = runner.run("smoke-after-deploy.sh", env: { "SETTLE_TIMEOUT_SECS" => "3" })

      expect(status.exitstatus).to eq(20)
      expect(out).to include("cms runs").and include("cms-stale")
      expect(runner.calls.grep(/workflow run/)).to be_empty
    end

    it "compares the box with the task definition it was rolled from, not always the latest" do
      settled_box(runner, images.merge("cms" => "#{registry}/widget-cms:cms-rollback"))
      runner.pin_task_definition("widget-platform:5", "website" => "website-old", "cms" => "cms-rollback",
                                                    "domain" => "domain-old")
      _out, _err, status = runner.run("smoke-after-deploy.sh", env: { "TASKDEF" => "widget-platform:5" })

      expect(status.exitstatus).to eq(0)
    end

    it "does not dispatch while a container is restarting or only just started (exit 20)", :aggregate_failures do
      restarting = ["website Up 3 minutes", "cms Restarting (1) 2 seconds ago", "domain Up 3 minutes", "caddy Up 3 minutes"]
      runner.box_report(compose: images, containers: restarting.join("\n"))
      _out, _err, status = runner.run("smoke-after-deploy.sh", env: { "SETTLE_TIMEOUT_SECS" => "3" })

      expect(status.exitstatus).to eq(20)
      expect(runner.calls.grep(/workflow run/)).to be_empty
    end

    it "stops at a failed stack", :aggregate_failures do
      settled_box(runner, images)
      runner.stack_status("UPDATE_ROLLBACK_COMPLETE")
      _out, err, status = runner.run("smoke-after-deploy.sh")

      expect(status.exitstatus).to eq(20)
      expect(err).to include("UPDATE_ROLLBACK_COMPLETE")
    end

    it "exits 22 when the smoke fails" do
      settled_box(runner, images)
      runner.stack_status("UPDATE_COMPLETE")
      _out, _err, status = runner.run("smoke-after-deploy.sh", env: { "STUB_CONCLUSION" => "failure" })

      expect(status.exitstatus).to eq(22)
    end

    it "honours SKIP_POST_DEPLOY_SMOKE", :aggregate_failures do
      settled_box(runner, images)
      out, _err, status = runner.run("smoke-after-deploy.sh", env: { "SKIP_POST_DEPLOY_SMOKE" => "1" })

      expect(status.exitstatus).to eq(0)
      expect(out).to include("SKIPPED")
      expect(runner.calls).to be_empty
    end

    it "honours DRY_RUN", :aggregate_failures do
      settled_box(runner, images)
      out, _err, status = runner.run("smoke-after-deploy.sh", env: { "DRY_RUN" => "1" })

      expect(status.exitstatus).to eq(0)
      expect(out).to include("Nothing dispatched")
      expect(runner.calls.grep(/workflow run/)).to be_empty
    end
  end

  describe "smoke-after-deploy.sh without a task definition" do
    runs_against :services_dir

    it "settles on the containers being up, with no image to compare", :aggregate_failures do
      settled_box(runner, "website" => "#{registry}/widget-shop-website:website-1", "cms" => "#{registry}/acme-cms:cms-1")
      out, err, status = runner.run("smoke-after-deploy.sh", env: { "REPO" => "" })

      expect(status.exitstatus).to eq(0), "#{out}\n#{err}"
      expect(runner.calls.grep(/\Agh repo view/)).not_to be_empty
    end
  end
end

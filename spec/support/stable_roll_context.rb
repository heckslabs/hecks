require_relative "deploy_roll_context"

# A roll that follows stable, driven through the launcher against the stand-in toolchain of the
# roll specs: the box-state read and the generated `deploy-service.sh` both meet the same stand-in
# `aws`. Nothing reaches AWS or GitHub.
module StableRollLooks
  # The stack names a generated `deploy-box.sh` assigns, added to the stand-in that only records
  # its arguments, so the box-state read finds them.
  NAMES = <<~BASH.freeze
    BOX_STACK=widget-box
    RDS_STACK=widget-rds
    REGION=us-east-1
    DIR=/opt/widget
  BASH

  # The roll reuses a tag already in ECR, as the roll specs do.
  ROLL_ENV = { "EXISTING_TAG" => "cms-old", "STUB_ECR_HAS_TAG" => "1" }.freeze

  # @return [String] the scratch project that holds the scripts
  def project = File.join(runner.dir, "scripts")

  # Sets what the box-state read lists: each service with the tag it runs.
  #
  # @param tags [Hash{String => String}] service => image tag
  # @return [void]
  def box_runs(tags)
    rows = tags.map { |name, tag| "#{name}\t#{registry}/widget-#{name}:#{tag}\tabc123\tUp 3 minutes\n" }
    File.write(File.join(runner.dir, "containers"), rows.join)
  end

  # Requests a roll of cms onto a promoted commit and answers the stable roll's record.
  #
  # @param run [String] the roll's key
  # @param auto_roll [Boolean] the service's switch
  # @param env [Hash{String => String, nil}] added to the stand-in environment; nil removes one
  # @return [Hash] the record, as the `Outcome` query answers it
  def follow_stable(run, auto_roll: true, env: {})
    words = ["run=#{run}", "service=cms", "project=#{project}", "promoted_commit=4f1c2d3", "auto_roll=#{auto_roll}"]
    with_stub_env(ROLL_ENV.merge(env).compact) { launch("stable_roll.request!", *words, "--wait") }
    JSON.parse(launch("stable_roll.outcome", "run=#{run}").first).first
  end

  # The status of the ServiceRoll the stable roll asked for, under the same key; nil when none ran.
  def service_roll_status(run)
    JSON.parse(launch("service_roll.verdict", "run=#{run}").first).first&.fetch("status")
  end

  def launch(*words)
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, program: "hecks", argv: ["deploy", *words])
  end

  def with_stub_env(env)
    settings = stub_env(env)
    saved = ENV.to_h.slice(*settings.keys)
    ENV.update(settings)
    yield
  ensure
    settings.each_key { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end
end

RSpec.shared_context "with a service that follows stable" do
  include_context "with the deploy roll stand-ins"
  include StableRollLooks

  with_stub_runner :taskdef_golden

  before do
    File.write(File.join(project, "deploy-box.sh"), StableRollLooks::NAMES, mode: "a")
    settled_and_pinned
    box_runs("cms" => "cms-old")
  end
end

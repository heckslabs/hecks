require "date"

Hecks.bluebook "Operations" do
  Deployment "AI model deployments across environments" do
    attribute :model_id, String
    environment String, enum: %w[development staging production]
    endpoint String
    purpose String
    audience String, enum: %w[internal customer-facing public]
    deployed_at DateTime
    decommissioned_at DateTime

    status String
    lifecycle :status, default: "planned" do
      transition "PlanDeployment"         => "planned"
      transition "DeployModel"            => "deployed",       from: "planned"
      transition "DecommissionDeployment" => "decommissioned", from: "deployed"
    end

    validation :model_id, presence: true
    validation :environment, presence: true

    plan_deployment do
      attribute :model_id, String
      environment String
      endpoint String
      purpose String
      audience String
    end

    scope :production, environment: "production"
    scope :customer_facing, audience: "customer-facing"

    deploy_model do
      deployment_id String
      sets deployed_at: :now
      external "DeploymentPipeline"
    end

    decommission_deployment do
      deployment_id String
      sets decommissioned_at: :now
    end

    specification "CustomerFacing" do |deployment|
      deployment.audience == "customer-facing" || deployment.audience == "public"
    end

    query :by_model do |model_id|
      where(model_id: model_id)
    end

    query :by_environment do |env|
      where(environment: env)
    end

    query :active do
      where(status: "deployed")
    end
  end

  Incident "AI-related incidents including bias, safety, and performance issues" do
    attribute :model_id, String
    severity String, enum: %w[low medium high critical]
    category String, enum: %w[bias safety privacy performance other]
    description String
    attribute :reported_by_id, String
    reported_at DateTime
    resolved_at DateTime
    resolution String
    root_cause String

    status String
    lifecycle :status, default: "reported" do
      transition "ReportIncident"      => "reported"
      transition "InvestigateIncident" => "investigating", from: "reported"
      transition "MitigateIncident"    => "mitigating",    from: "investigating"
      transition "ResolveIncident"     => "resolved",      from: ["investigating", "mitigating"]
      transition "CloseIncident"       => "closed",        from: "resolved"
    end

    validation :model_id, presence: true
    validation :severity, presence: true

    scope :critical, severity: "critical"
    scope :open_incidents, status: "reported"

    report_incident do
      attribute :model_id, String
      severity String
      category String
      description String
      attribute :reported_by_id, String
      sets reported_at: :now
      external "AlertingService"
    end

    investigate_incident do
      incident_id String
    end

    mitigate_incident do
      incident_id String
    end

    resolve_incident do
      incident_id String
      resolution String
      root_cause String
      sets resolved_at: :now
    end

    close_incident do
      incident_id String
    end

    specification "Critical" do |incident|
      incident.severity == "critical" || incident.category == "safety"
    end

    on_event "ReportedIncident", async: true do |event|
      # Side-effect: page on-call when critical incident reported
    end

    query :by_model do |model_id|
      where(model_id: model_id)
    end

    query :by_severity do |severity|
      where(severity: severity)
    end

    query :open do
      where(status: "reported")
    end
  end

  Monitoring "Performance and safety metrics for deployed models" do
    attribute :model_id, String
    attribute :deployment_id, reference_to("Deployment")
    metric_name String
    value Float
    threshold Float
    recorded_at DateTime

    validation :model_id, presence: true
    validation :metric_name, presence: true

    invariant "threshold must be positive" do
      !threshold || threshold > 0
    end

    record_metric do
      attribute :model_id, String
      attribute :deployment_id, reference_to("Deployment")
      metric_name String
      value Float
      threshold Float
      sets recorded_at: :now
    end

    set_threshold do
      monitoring_id String
      threshold Float
      sets threshold: :threshold
    end

    specification "ThresholdBreached" do |m|
      m.threshold && m.value && m.value > m.threshold
    end

    query :by_model do |model_id|
      where(model_id: model_id)
    end

    query :by_deployment do |deployment_id|
      where(deployment_id: deployment_id)
    end
  end

  # Intra-domain: Incident -> Incident (auto-triage, auto-close)
  policy "AutoTriage" do
    on "ReportedIncident"             # from Operations::Incident
    trigger "InvestigateIncident"     # on   Operations::Incident
    map incident_id: :id
  end

  policy "AutoClose" do
    on "ResolvedIncident"             # from Operations::Incident
    trigger "CloseIncident"           # on   Operations::Incident
    map incident_id: :id
  end
end

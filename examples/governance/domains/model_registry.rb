require "date"

Hecks.domain "ModelRegistry" do
  AiModel "AI models registered for governance oversight" do
    name String
    version String
    attribute :provider_id, reference_to("Vendor")
    description String
    risk_level String, enum: %w[low medium high critical]
    registered_at DateTime
    attribute :parent_model_id, String
    derivation_type String, enum: %w[fine-tuned distilled retrained quantized]
    capabilities list_of("Capability")
    intended_uses list_of("IntendedUse")

    status String
    lifecycle :status, default: "draft" do
      transition "RegisterModel"  => "draft"
      transition "DeriveModel"    => "draft"
      transition "ClassifyRisk"   => "classified", from: "draft"
      transition "ApproveModel"   => "approved",   from: "classified"
      transition "SuspendModel"   => "suspended",  from: ["approved", "classified", "draft"]
      transition "RetireModel"    => "retired",    from: ["approved", "suspended"]
    end

    Capability do
      name String
      category String
    end

    IntendedUse do
      description String
      domain String
    end

    validation :name, presence: true
    validation :version, presence: true

    register_model do
      name String
      version String
      attribute :provider_id, reference_to("Vendor")
      description String
      sets registered_at: :now
    end

    derive_model do
      name String
      version String
      attribute :parent_model_id, String
      derivation_type String
      description String
      sets registered_at: :now
    end

    classify_risk do
      model_id String
      risk_level String
      sets risk_level: :risk_level
    end

    approve_model do
      model_id String
      precondition("Model must be classified before approval") { |cmd| cmd.respond_to?(:risk_level) }
      actor "governance_board"
      actor "admin"
    end

    suspend_model do
      model_id String
      external "NotificationGateway"
      actor "governance_board"
      actor "admin"
    end

    retire_model do
      model_id String
      actor "governance_board"
      actor "admin"
    end

    specification "HighRisk" do |model|
      model.risk_level == "high" || model.risk_level == "critical"
    end

    scope :approved, status: "approved"
    scope :suspended, status: "suspended"

    query :by_provider do |provider_id|
      where(provider_id: provider_id)
    end

    query :by_risk_level do |level|
      where(risk_level: level)
    end

    query :by_status do |status|
      where(status: status)
    end

    query :by_parent do |parent_id|
      where(parent_model_id: parent_id)
    end

    # Cross-domain reactive policies
    policy "ClassifyAfterAssessment" do
      on "SubmittedAssessment"
      trigger "ClassifyRisk"
      map model_id: :model_id, risk_level: :risk_level
    end

    policy "SuspendOnReject" do
      on "RejectedReview"
      trigger "SuspendModel"
      map model_id: :model_id
    end

    policy "SuspendOnCriticalIncident" do
      on "ReportedIncident"
      trigger "SuspendModel"
      map model_id: :model_id
      condition { |event| event.severity == "critical" }
      async true
    end

    on_event "SuspendedModel" do |event|
      # Side-effect: notify vendor when their model is suspended
    end
  end

  Vendor "Third-party AI model providers and their risk assessments" do
    name String
    contact_email String, pii: true
    risk_tier String, enum: %w[low medium high]
    assessment_date Date
    next_review_date Date
    sla_terms String

    status String
    lifecycle :status, default: "pending_review" do
      transition "RegisterVendor" => "pending_review"
      transition "ApproveVendor"  => "approved",  from: "pending_review"
      transition "SuspendVendor"  => "suspended", from: "approved"
    end

    validation :name, presence: true

    register_vendor do
      name String
      contact_email String
      risk_tier String
    end

    approve_vendor do
      vendor_id String
      assessment_date Date
      next_review_date Date
      actor "governance_board"
      actor "admin"
    end

    suspend_vendor do
      vendor_id String
      actor "governance_board"
      actor "admin"
    end

    query :by_risk_tier do |tier|
      where(risk_tier: tier)
    end

    query :active do
      where(status: "approved")
    end
  end

  DataUsageAgreement "Agreements governing data usage for model training and inference" do
    attribute :model_id, reference_to("AiModel")
    data_source String
    purpose String
    consent_type String, enum: %w[public_domain CC-BY-SA licensed consent opt-out]
    effective_date Date
    expiration_date Date
    restrictions list_of("Restriction")

    status String
    lifecycle :status, default: "draft" do
      transition "CreateAgreement"   => "draft"
      transition "ActivateAgreement" => "active",  from: "draft"
      transition "RevokeAgreement"   => "revoked", from: "active"
      transition "RenewAgreement"    => "active",  from: ["active", "revoked"]
    end

    Restriction do
      type String
      description String
    end

    validation :data_source, presence: true
    validation :purpose, presence: true

    invariant "expiration must be after effective date" do
      !expiration_date || !effective_date || expiration_date.to_s >= effective_date.to_s
    end

    create_agreement do
      attribute :model_id, reference_to("AiModel")
      data_source String
      purpose String
      consent_type String
      actor "data_steward"
      actor "admin"
    end

    activate_agreement do
      agreement_id String
      effective_date Date
      expiration_date Date
      actor "data_steward"
      actor "admin"
    end

    revoke_agreement do
      agreement_id String
      actor "data_steward"
      actor "admin"
    end

    renew_agreement do
      agreement_id String
      expiration_date Date
      actor "data_steward"
      actor "admin"
    end

    specification "Expired" do |agreement|
      agreement.expiration_date && agreement.expiration_date.to_s < Date.today.to_s
    end

    query :by_model do |model_id|
      where(model_id: model_id)
    end

    query :active do
      where(status: "active")
    end
  end

  workflow "ModelApproval" do
    step "SubmitAssessment"
    branch do
      when_spec("HighRisk") { step "OpenReview" }
      otherwise { step "ApproveModel" }
    end
  end

  # Intra-domain: AiModel -> AiModel (auto-approve low-risk after classification)
  policy "AutoApproveLowRisk" do
    on "ClassifiedRisk"               # from ModelRegistry::AiModel
    trigger "ApproveModel"            # on   ModelRegistry::AiModel
    map model_id: :model_id
    condition { |event| event.risk_level == "low" }
  end

  view "ModelDashboard" do
    project("RegisteredModel") do |event, state|
      state.merge(total_models: (state[:total_models] || 0) + 1)
    end

    project("ClassifiedRisk") do |event, state|
      risk = event.respond_to?(:risk_level) ? event.risk_level : "unknown"
      by_risk = state[:models_by_risk] || {}
      state.merge(models_by_risk: by_risk.merge(risk => (by_risk[risk] || 0) + 1))
    end

    project("SuspendedModel") do |event, state|
      state.merge(suspended_count: (state[:suspended_count] || 0) + 1)
    end
  end
end

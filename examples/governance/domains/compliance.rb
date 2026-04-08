require "date"

Hecks.bluebook "Compliance" do
  GovernancePolicy "Organizational policies governing AI model usage and compliance" do
    name String
    description String
    category String, enum: %w[regulatory internal ethical operational]
    attribute :framework_id, reference_to("RegulatoryFramework")
    effective_date Date
    review_date Date
    requirements list_of("Requirement")

    status String
    lifecycle :status, default: "draft" do
      transition "CreatePolicy"   => "draft"
      transition "ActivatePolicy" => "active",    from: "draft"
      transition "SuspendPolicy"  => "suspended", from: "active"
      transition "RetirePolicy"   => "retired",   from: ["active", "suspended"]
    end

    Requirement do
      description String
      priority String, enum: %w[low medium high critical]
      category String
    end

    validation :name, presence: true
    validation :category, presence: true

    create_policy do
      name String
      description String
      category String
      attribute :framework_id, reference_to("RegulatoryFramework")
      actor "governance_board"
      actor "admin"
    end

    activate_policy do
      policy_id String
      effective_date Date
      actor "governance_board"
      actor "admin"
    end

    suspend_policy do
      policy_id String
      actor "governance_board"
      actor "admin"
    end

    retire_policy do
      policy_id String
      actor "governance_board"
      actor "admin"
    end

    update_review_date do
      policy_id String
      review_date Date
      actor "governance_board"
      actor "admin"
    end

    scope :active_policies, status: "active"
    scope :draft_policies, status: "draft"

    query :by_category do |category|
      where(category: category)
    end

    query :by_framework do |framework_id|
      where(framework_id: framework_id)
    end

    query :active do
      where(status: "active")
    end
  end

  RegulatoryFramework "External regulatory requirements and their articles" do
    name String
    jurisdiction String
    version String
    effective_date Date
    authority String
    requirements list_of("FrameworkRequirement")

    status String
    lifecycle :status, default: "draft" do
      transition "RegisterFramework" => "draft"
      transition "ActivateFramework" => "active",  from: "draft"
      transition "RetireFramework"   => "retired", from: "active"
    end

    FrameworkRequirement do
      article String
      section String
      description String
      risk_category String
    end

    validation :name, presence: true
    validation :jurisdiction, presence: true

    register_framework do
      name String
      jurisdiction String
      version String
      authority String
    end

    activate_framework do
      framework_id String
      effective_date Date
    end

    retire_framework do
      framework_id String
    end

    query :by_jurisdiction do |jurisdiction|
      where(jurisdiction: jurisdiction)
    end

    query :active do
      where(status: "active")
    end
  end

  ComplianceReview "Reviews of AI models against governance policies" do
    attribute :model_id, String
    attribute :policy_id, reference_to("GovernancePolicy")
    attribute :reviewer_id, String
    outcome String, enum: %w[approved rejected]
    notes String
    completed_at DateTime
    conditions list_of("ReviewCondition")

    status String
    lifecycle :status, default: "open" do
      transition "OpenReview"      => "open"
      transition "ApproveReview"   => "approved",          from: ["open", "changes_requested"]
      transition "RejectReview"    => "rejected",          from: ["open", "changes_requested"]
      transition "RequestChanges"  => "changes_requested", from: "open"
    end

    ReviewCondition do
      requirement String
      met String, enum: %w[yes no partial]
      evidence String
    end

    validation :model_id, presence: true
    validation :reviewer_id, presence: true

    open_review do
      attribute :model_id, String
      attribute :policy_id, reference_to("GovernancePolicy")
      attribute :reviewer_id, String
      actor "reviewer"
      actor "admin"
    end

    approve_review do
      review_id String
      notes String
      sets outcome: "approved", completed_at: :now
      external "NotificationGateway"
      actor "reviewer"
      actor "admin"
    end

    reject_review do
      review_id String
      notes String
      sets outcome: "rejected", completed_at: :now
      external "NotificationGateway"
      actor "reviewer"
      actor "admin"
    end

    request_changes do
      review_id String
      notes String
      actor "reviewer"
      actor "admin"
    end

    on_event "RejectedReview" do |event|
      # Side-effect: notify model owner of rejection
    end

    scope :open_reviews, status: "open"

    query :by_model do |model_id|
      where(model_id: model_id)
    end

    query :pending do
      where(status: "open")
    end

    query :by_reviewer do |reviewer_id|
      where(reviewer_id: reviewer_id)
    end
  end

  Exemption "Approved exceptions to policy requirements" do
    attribute :model_id, String
    attribute :policy_id, reference_to("GovernancePolicy")
    requirement String
    reason String
    attribute :approved_by_id, String
    approved_at DateTime
    expires_at Date
    attribute :scope, String

    status String
    lifecycle :status, default: "requested" do
      transition "RequestExemption" => "requested"
      transition "ApproveExemption" => "active",  from: "requested"
      transition "RevokeExemption"  => "revoked", from: "active"
    end

    validation :model_id, presence: true
    validation :policy_id, presence: true

    request_exemption do
      attribute :model_id, String
      attribute :policy_id, reference_to("GovernancePolicy")
      requirement String
      reason String
    end

    approve_exemption do
      exemption_id String
      attribute :approved_by_id, String
      expires_at Date
      sets approved_at: :now
      actor "governance_board"
      actor "admin"
    end

    revoke_exemption do
      exemption_id String
      actor "governance_board"
      actor "admin"
    end

    specification "Expired" do |e|
      e.expires_at && e.expires_at.to_s < Date.today.to_s
    end

    query :by_model do |model_id|
      where(model_id: model_id)
    end

    query :active do
      where(status: "active")
    end
  end

  TrainingRecord "Staff training completion and certification tracking" do
    attribute :stakeholder_id, String
    attribute :policy_id, reference_to("GovernancePolicy")
    completed_at DateTime
    expires_at Date
    certification String

    status String
    lifecycle :status, default: "assigned" do
      transition "AssignTraining"   => "assigned"
      transition "CompleteTraining" => "completed", from: "assigned"
      transition "RenewTraining"    => "completed", from: "completed"
    end

    validation :stakeholder_id, presence: true
    validation :policy_id, presence: true

    invariant "expires_at must be after completed_at" do
      !expires_at || !completed_at || expires_at.to_s >= completed_at.to_s[0, 10]
    end

    assign_training do
      attribute :stakeholder_id, String
      attribute :policy_id, reference_to("GovernancePolicy")
    end

    complete_training do
      training_record_id String
      certification String
      expires_at Date
      sets completed_at: :now
    end

    renew_training do
      training_record_id String
      certification String
      expires_at Date
      sets completed_at: :now
    end

    specification "Expired" do |t|
      t.expires_at && t.expires_at.to_s < Date.today.to_s
    end

    query :by_stakeholder do |stakeholder_id|
      where(stakeholder_id: stakeholder_id)
    end

    query :by_policy do |policy_id|
      where(policy_id: policy_id)
    end

    query :incomplete do
      where(status: "assigned")
    end
  end
end

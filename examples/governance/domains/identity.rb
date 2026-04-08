require "date"

Hecks.bluebook "Identity" do
  Stakeholder "Users, roles, and permissions for governance participants" do
    name String, pii: true
    email String, pii: true
    role String, enum: %w[assessor reviewer governance_board data_steward incident_reporter admin auditor]
    team String

    status String
    lifecycle :status, default: "active" do
      transition "RegisterStakeholder"   => "active"
      transition "DeactivateStakeholder" => "deactivated", from: "active"
    end

    validation :name, presence: true
    validation :email, presence: true

    register_stakeholder do
      name String
      email String
      role String
      team String
    end

    assign_role do
      stakeholder_id String
      role String
      sets role: :role
    end

    deactivate_stakeholder do
      stakeholder_id String
      actor "admin"
    end

    scope :admins, role: "admin"
    scope :auditors, role: "auditor"

    query :by_role do |role|
      where(role: role)
    end

    query :by_team do |team|
      where(team: team)
    end

    query :active do
      where(status: "active")
    end
  end

  AuditLog "Immutable record of all actions across the governance system" do
    entity_type String
    entity_id String
    action String
    attribute :actor_id, reference_to("Stakeholder")
    details String
    timestamp DateTime

    validation :entity_type, presence: true
    validation :action, presence: true

    record_entry do
      entity_type String
      entity_id String
      action String
      attribute :actor_id, reference_to("Stakeholder")
      details String
      sets timestamp: :now
    end

    query :by_entity do |entity_type, entity_id|
      where(entity_type: entity_type, entity_id: entity_id)
    end

    query :by_actor do |actor_id|
      where(actor_id: actor_id)
    end

    # Cross-domain audit policies
    policy "AuditModelRegistration" do
      on "RegisteredModel"
      trigger "RecordEntry"
      map name: :details
      defaults entity_type: "AiModel", action: "registered", actor_id: "system"
    end

    policy "AuditModelSuspension" do
      on "SuspendedModel"
      trigger "RecordEntry"
      defaults entity_type: "AiModel", action: "suspended", actor_id: "system"
    end

    policy "AuditIncidentReport" do
      on "ReportedIncident"
      trigger "RecordEntry"
      map description: :details
      defaults entity_type: "Incident", action: "reported", actor_id: "system"
    end
  end

  # Intra-domain: Stakeholder -> AuditLog
  policy "AuditDeactivation" do
    on "DeactivatedStakeholder"       # from Identity::Stakeholder
    trigger "RecordEntry"             # on   Identity::AuditLog
    defaults entity_type: "Stakeholder", action: "deactivated", actor_id: "system"
  end
end

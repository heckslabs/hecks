#!/usr/bin/env ruby
#
# Demo: walks through the full governance lifecycle.
#
# Run:  ruby examples/demo.rb
#
require_relative "../app"
puts "=== AI Governance Platform (5 domains, 14 aggregates) ==="
Hecks.actor = OpenStruct.new(role: "admin")

puts "\n--- Identity: Register stakeholders ---"
alice = Stakeholder.register(name: "Alice Chen", email: "alice@gov.ai", role: "assessor", team: "risk")
bob = Stakeholder.register(name: "Bob Park", email: "bob@gov.ai", role: "reviewer", team: "compliance")
puts "Stakeholders: #{Stakeholder.count}"

puts "\n--- Model Registry: Register vendor and models ---"
openai = Vendor.register(name: "OpenAI", contact_email: "e@openai.com", risk_tier: "high")
gpt = AiModel.register(name: "GPT-5", version: "1.0", provider_id: openai.id, description: "LLM")
claude_vendor = Vendor.register(name: "Anthropic", contact_email: "e@anthropic.com", risk_tier: "low")
claude = AiModel.register(name: "Claude-4", version: "4.0", provider_id: claude_vendor.id, description: "Constitutional AI")
puts "Models: #{AiModel.count}, Vendors: #{Vendor.count}"

puts "\n--- Model Registry: Data usage agreements ---"
DataUsageAgreement.create(model_id: gpt.id, data_source: "CommonCrawl", purpose: "Pre-training", consent_type: "public_domain")
puts "Agreements: #{DataUsageAgreement.count}"

puts "\n--- Risk Assessment: Assess GPT-5 ---"
assessment = Assessment.initiate(model_id: gpt.id, assessor_id: alice.id)
Assessment.submit(
  assessment_id: assessment.id, risk_level: "high",
  bias_score: 0.35, safety_score: 0.72,
  transparency_score: 0.5, overall_score: 0.52
)
gpt = AiModel.find(gpt.id)
puts "GPT-5 risk: #{gpt.risk_level}, status: #{gpt.status}"

puts "\n--- Risk Assessment: Assess Claude-4 ---"
assessment2 = Assessment.initiate(model_id: claude.id, assessor_id: alice.id)
Assessment.submit(
  assessment_id: assessment2.id, risk_level: "low",
  bias_score: 0.1, safety_score: 0.95,
  transparency_score: 0.9, overall_score: 0.92
)
claude = AiModel.find(claude.id)
puts "Claude risk: #{claude.risk_level}, status: #{claude.status}"

puts "\n--- Compliance: Setup framework and policy ---"
eu_ai = RegulatoryFramework.register(name: "EU AI Act", jurisdiction: "EU", version: "2024", authority: "EC")
RegulatoryFramework.activate(framework_id: eu_ai.id, effective_date: Date.today)
policy = GovernancePolicy.create(name: "EU AI Act High-Risk", description: "High-risk regulation", category: "regulatory", framework_id: eu_ai.id)
GovernancePolicy.activate(policy_id: policy.id, effective_date: Date.today)
puts "Policies: #{GovernancePolicy.count}"

puts "\n--- Compliance: Review Claude → approve ---"
review = ComplianceReview.open(model_id: claude.id, policy_id: policy.id, reviewer_id: bob.id)
ComplianceReview.approve(review_id: review.id, notes: "All requirements met")
AiModel.approve(model_id: claude.id)
claude = AiModel.find(claude.id)
puts "Claude: #{claude.status}, approved? #{claude.approved?}"

puts "\n--- Compliance: Review GPT-5 → reject (triggers suspend via event) ---"
review2 = ComplianceReview.open(model_id: gpt.id, policy_id: policy.id, reviewer_id: bob.id)
ComplianceReview.reject(review_id: review2.id, notes: "Insufficient bias mitigation")
gpt = AiModel.find(gpt.id)
puts "GPT-5: #{gpt.status}, suspended? #{gpt.suspended?}"

puts "\n--- Operations: Deploy Claude ---"
dep = Deployment.plan(model_id: claude.id, environment: "production", endpoint: "api.co/chat", purpose: "Support", audience: "customer-facing")
Deployment.deploy_model(deployment_id: dep.id)
puts "Deployments: #{Deployment.active.size}"

puts "\n--- Operations: Monitor Claude ---"
Monitoring.record_metric(model_id: claude.id, deployment_id: dep.id, metric_name: "bias_drift", value: 0.02, threshold: 0.1)
puts "Metrics: #{Monitoring.by_model(claude.id).size}"

puts "\n--- Operations: Report incident on GPT-5 ---"
Incident.report(model_id: gpt.id, severity: "high", category: "bias", description: "Gender bias in hiring", reported_by_id: bob.id)
puts "Open incidents: #{Incident.open.size}"

puts "\n--- Compliance: Exemption and training ---"
exemption = Exemption.request(model_id: gpt.id, policy_id: policy.id, requirement: "Transparency docs", reason: "In progress")
Exemption.approve(exemption_id: exemption.id, approved_by_id: bob.id, expires_at: Date.new(2026, 6, 1))
training = TrainingRecord.assign_training(stakeholder_id: alice.id, policy_id: policy.id)
TrainingRecord.complete_training(training_record_id: training.id, certification_id: "CERT-001", expires_at: Date.new(2027, 3, 25))
puts "Exemptions: #{Exemption.active.size}, Training: #{TrainingRecord.count}"

puts "\n--- Cross-domain event flow ---"
puts "Shared event bus: #{Hecks.event_bus.events.size} events"
Hecks.event_bus.events.each_with_index do |event, i|
  puts "  #{i + 1}. #{event.class.name.split('::').last}"
end

puts "\n--- Audit trail ---"
puts "Audit entries: #{AuditLog.count}"
puts "Command audit: #{Hecks.audit_log.size} entries"

puts "\n--- PII protection ---"
[IdentityDomain, ModelRegistryDomain].each do |mod|
  pii = mod.pii_fields
  pii.each { |agg, fields| puts "  #{mod.name.sub('Domain', '')}::#{agg}: #{fields.join(', ')}" } unless pii.empty?
end
puts "  Masked email: #{Hecks::PII.mask("alice@governance.ai")}"

puts "\n--- Final state ---"
{ "AiModel" => AiModel, "Vendor" => Vendor, "DataUsageAgreement" => DataUsageAgreement,
  "Assessment" => Assessment, "GovernancePolicy" => GovernancePolicy,
  "RegulatoryFramework" => RegulatoryFramework, "ComplianceReview" => ComplianceReview,
  "Exemption" => Exemption, "TrainingRecord" => TrainingRecord,
  "Deployment" => Deployment, "Incident" => Incident, "Monitoring" => Monitoring,
  "Stakeholder" => Stakeholder, "AuditLog" => AuditLog
}.each { |name, klass| puts "  #{name}: #{klass.count}" }

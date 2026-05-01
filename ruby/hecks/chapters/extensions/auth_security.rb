# = Hecks::Chapters::Extensions::AuthSecurity
#
# Self-describing sub-chapter for authentication and security
# extensions: actor auth/authz, audit trail, PII management,
# rate limiting, and idempotency key tracking.
#
#   Hecks::Chapters::Extensions::AuthSecurity.define(builder)
#
module Hecks
  module Chapters
    module Extensions
      # Hecks::Chapters::Extensions::AuthSecurity
      #
      # Bluebook sub-chapter for auth and security extensions: auth, audit, PII, rate limiting, and idempotency.
      #
      module AuthSecurity
        def self.define(b)
          b.aggregate "Auth", "Actor-based authentication and authorization" do
            command("Authenticate") { attribute :actor, String }
            command("Authorize") { attribute :command_name, String; attribute :role, String }
          end

          b.aggregate "Audit", "Command execution audit trail" do
            command("Record") { attribute :command_name, String; attribute :actor, String }
          end

          b.aggregate "PII", "PII attribute marking, masking, and erasure" do
            command("MarkPII") { attribute :field, String }
            command("Erase") { attribute :aggregate_id, String }
          end

          b.aggregate "RateLimit", "Per-command rate limiting" do
            command("Check") { attribute :command_name, String; attribute :actor, String }
          end

          b.aggregate "Idempotency", "Idempotency key tracking for commands" do
            command("Check") { attribute :idempotency_key, String }
          end
        end
      end
    end
  end
end

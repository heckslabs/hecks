# Hecks::Binding::ErrorsParagraph
#
# Paragraph covering the Hecks error hierarchy. Each error class is
# modeled as an aggregate with a Raise command carrying the parameters
# that the actual constructor accepts.
#
#   Hecks::Binding::ErrorsParagraph.define(builder)
#
module Hecks
  module Chapters
    module Binding
    # Hecks::Binding::ErrorsParagraph
    #
    # Bluebook sub-chapter modeling the Hecks error hierarchy as aggregates with Raise commands.
    #
    module ErrorsParagraph
      def self.define(b)
        b.aggregate "Error", "Base error class for all Hecks domain errors" do
          command("Throw") { attribute :message, String }
        end

        b.aggregate "ValidationError", "Raised when attribute or aggregate validation fails" do
          command("Throw") { attribute :message, String; attribute :errors, String }
        end

        b.aggregate "GuardRejected", "Raised when a guard policy blocks command execution" do
          command("Throw") { attribute :message, String; attribute :guard_name, String }
        end

        b.aggregate "PreconditionError", "Raised when a command precondition is not met" do
          command("Throw") { attribute :message, String; attribute :precondition, String }
        end

        b.aggregate "PostconditionError", "Raised when a command postcondition check fails" do
          command("Throw") { attribute :message, String; attribute :postcondition, String }
        end

        b.aggregate "DomainLoadError", "Raised when a domain gem cannot be loaded" do
          command("Throw") { attribute :message, String }
        end

        b.aggregate "InvalidDomainVersion", "Raised when a domain version string is malformed" do
          command("Throw") { attribute :message, String }
        end

        b.aggregate "MigrationError", "Raised when a domain migration fails" do
          command("Throw") { attribute :message, String }
        end

        b.aggregate "ConfigurationError", "Raised when Hecks.configure has invalid settings" do
          command("Throw") { attribute :message, String }
        end

        b.aggregate "GateAccessDenied", "Raised when a gate blocks method access for a role" do
          command("Throw") { attribute :message, String }
        end

        b.aggregate "Unauthenticated", "Raised when no identity is provided for a gated operation" do
          command("Throw") { attribute :message, String }
        end

        b.aggregate "Unauthorized", "Raised when identity lacks permission for an operation" do
          command("Throw") { attribute :message, String }
        end

        b.aggregate "RateLimitExceeded", "Raised when a rate-limited operation exceeds its quota" do
          command("Throw") { attribute :message, String }
        end

        b.aggregate "ConcurrencyError", "Raised on optimistic locking version conflict" do
          command("Throw") { attribute :message, String }
        end

        b.aggregate "PathTraversalDetected", "Raised when a file path attempts directory traversal" do
          command("Throw") { attribute :message, String; attribute :path, String }
        end

        b.aggregate "ReferenceNotFound", "Raised when a cross-aggregate reference target is missing" do
          command("Throw") { attribute :message, String; attribute :reference_type, String }
        end

        b.aggregate "ReferenceAccessDenied", "Raised when IDOR validation blocks a reference access" do
          command("Throw") { attribute :message, String; attribute :reference_type, String }
        end
      end
      end
    end
  end
end

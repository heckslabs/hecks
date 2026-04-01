# = Hecks::Errors
#
# Custom error hierarchy for the Hecks framework. All Hecks exceptions
# inherit from {Hecks::Error}, which itself inherits from +StandardError+.
#
# This module defines specific exception types for different failure modes
# across the framework:
#
# - *Validation* -- Domain model validation failures (e.g., missing attributes,
#   invalid types)
# - *Guards* -- Command guard rejections (precondition checks that block execution)
# - *Conditions* -- Pre/post-condition contract violations
# - *Domain loading* -- Failures when parsing or compiling domain definitions
# - *Migrations* -- Schema migration errors (e.g., column conflicts)
# - *Configuration* -- Invalid or missing configuration settings
# - *Access control* -- Port access, authentication, authorization, and rate limiting
#
# == Usage
#
#   raise Hecks::GuardRejected, "Must be admin"
#   raise Hecks::MigrationError, "Column already exists"
#   raise Hecks::ValidationError, "Name cannot be blank"
#
#   begin
#     app["Pizza"].create(name: "")
#   rescue Hecks::ValidationError => e
#     puts e.message
#   end
#
module Hecks
  # Base error class for all Hecks framework exceptions. Rescue this to
  # catch any Hecks-specific error. Provides +as_json+ and +to_json+ for
  # structured error output suitable for MCP and HTTP responses.
  class Error < StandardError
    # Returns a structured Hash representation of this error.
    #
    # @return [Hash] with :error (class name) and :message keys
    def as_json
      { error: Hecks::Utils.const_short_name(self), message: message }
    end

    # Returns a JSON string representation of this error.
    #
    # @return [String] JSON-encoded error data
    def to_json(*_args)
      JSON.generate(as_json)
    end
  end

  # Raised when a domain model fails validation (e.g., blank required
  # attribute, invalid enum value, type mismatch).
  #
  # Accepts optional +field+ and +rule+ for attribute-level detail.
  #
  #   raise Hecks::ValidationError.new("Name cannot be blank", field: :name, rule: :presence)
  class ValidationError < Error
    # @return [Symbol, String, nil] the field that failed validation
    attr_reader :field

    # @return [Symbol, String, nil] the rule that was violated (e.g. :presence, :type, :uniqueness)
    attr_reader :rule

    # @param message [String] human-readable error message
    # @param field [Symbol, String, nil] the attribute that failed validation
    # @param rule [Symbol, String, nil] the validation rule that was violated
    def initialize(message = nil, field: nil, rule: nil)
      @field = field
      @rule = rule
      super(message)
    end

    # Returns structured error data including field and rule when present.
    #
    # @return [Hash] error data with :error, :message, and optionally :field, :rule
    def as_json
      h = super
      h[:field] = field.to_s if field
      h[:rule] = rule.to_s if rule
      h
    end
  end

  # Raised when a command guard rejects execution. Guards are precondition
  # checks defined on commands that prevent invalid state transitions.
  #
  # Accepts optional +command+ and +aggregate+ context.
  #
  #   raise Hecks::GuardRejected.new("Insufficient funds",
  #     command: "Withdraw", aggregate: "Account", fix: "Check balance first")
  class GuardRejected < Error
    # @return [String, nil] the command name that was rejected
    attr_reader :command

    # @return [String, nil] the aggregate the command targets
    attr_reader :aggregate

    # @return [String, nil] a suggestion for how to fix the issue
    attr_reader :fix

    # @param message [String] human-readable error message
    # @param command [String, nil] the rejected command name
    # @param aggregate [String, nil] the target aggregate name
    # @param fix [String, nil] remediation suggestion
    def initialize(message = nil, command: nil, aggregate: nil, fix: nil)
      @command = command
      @aggregate = aggregate
      @fix = fix
      super(message)
    end

    # Returns structured error data with command context.
    #
    # @return [Hash] error data with :error, :message, :command, :aggregate, :fix
    def as_json
      h = super
      h[:command] = command if command
      h[:aggregate] = aggregate if aggregate
      h[:fix] = fix if fix
      h
    end
  end

  # Raised when a precondition (defined via +pre+ in a lifecycle) is not met
  # before a command executes.
  #
  # Accepts optional +invariant+ for the condition message.
  #
  #   raise Hecks::PreconditionError.new("Precondition failed: balance >= 0",
  #     invariant: "balance >= 0")
  class PreconditionError < Error
    # @return [String, nil] the invariant/condition message that failed
    attr_reader :invariant

    # @param message [String] human-readable error message
    # @param invariant [String, nil] the precondition description
    def initialize(message = nil, invariant: nil)
      @invariant = invariant
      super(message)
    end

    # Returns structured error data with invariant detail.
    #
    # @return [Hash] error data with :error, :message, and optionally :invariant
    def as_json
      h = super
      h[:invariant] = invariant if invariant
      h
    end
  end

  # Raised when a postcondition (defined via +post+ in a lifecycle) is not met
  # after a command executes, indicating the command produced invalid state.
  #
  # Accepts optional +invariant+ for the condition message.
  class PostconditionError < Error
    # @return [String, nil] the invariant/condition message that failed
    attr_reader :invariant

    # @param message [String] human-readable error message
    # @param invariant [String, nil] the postcondition description
    def initialize(message = nil, invariant: nil)
      @invariant = invariant
      super(message)
    end

    # Returns structured error data with invariant detail.
    #
    # @return [Hash] error data with :error, :message, and optionally :invariant
    def as_json
      h = super
      h[:invariant] = invariant if invariant
      h
    end
  end

  # Raised when a domain definition cannot be loaded or parsed (e.g.,
  # missing domain.rb file, syntax error in DSL, unresolvable references).
  class DomainLoadError < Error; end

  # Raised when a schema migration fails (e.g., attempting to add a column
  # that already exists, incompatible type change).
  class MigrationError < Error; end

  # Raised when configuration is invalid or incomplete (e.g., missing
  # required adapter setting, unknown extension name).
  class ConfigurationError < Error; end

  # Raised when code attempts to access a port (command, query, repository)
  # that is not exposed or not permitted for the current context.
  class GateAccessDenied < Error; end

  # Raised when an operation requires authentication but no actor is set
  # (i.e., +Hecks.actor+ is nil).
  class Unauthenticated < Error; end

  # Raised when the current actor does not have permission to perform the
  # requested operation (actor is set but lacks required role/privilege).
  class Unauthorized < Error; end

  # Raised when a rate limit is exceeded for a command or query operation.
  class RateLimitExceeded < Error; end
end

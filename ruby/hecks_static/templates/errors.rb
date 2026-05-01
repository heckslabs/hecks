# __DOMAIN_MODULE__::Runtime::Errors
#
# Error hierarchy for the domain. All domain exceptions inherit from
# __DOMAIN_MODULE__::Error. Provides as_json/to_json for structured
# error output in HTTP and MCP responses.

module __DOMAIN_MODULE__
  class Error < StandardError
    def as_json
      { error: self.class.name.split("::").last, message: message }
    end

    def to_json(*_args)
      require "json"
      JSON.generate(as_json)
    end
  end

  class ValidationError < Error
    attr_reader :field, :rule
    def initialize(message = nil, field: nil, rule: nil)
      @field = field
      @rule = rule
      super(message)
    end

    def as_json
      h = super
      h[:field] = field.to_s if field
      h[:rule] = rule.to_s if rule
      h
    end
  end

  class InvariantError < Error; end

  class GuardRejected < Error
    attr_reader :command, :aggregate, :fix
    def initialize(message = nil, command: nil, aggregate: nil, fix: nil)
      @command = command
      @aggregate = aggregate
      @fix = fix
      super(message)
    end

    def as_json
      h = super
      h[:command] = command if command
      h[:aggregate] = aggregate if aggregate
      h[:fix] = fix if fix
      h
    end
  end

  class PreconditionError < Error
    attr_reader :invariant
    def initialize(message = nil, invariant: nil)
      @invariant = invariant
      super(message)
    end

    def as_json
      h = super
      h[:invariant] = invariant if invariant
      h
    end
  end

  class PostconditionError < Error
    attr_reader :invariant
    def initialize(message = nil, invariant: nil)
      @invariant = invariant
      super(message)
    end

    def as_json
      h = super
      h[:invariant] = invariant if invariant
      h
    end
  end

  class GateAccessDenied < Error; end
end

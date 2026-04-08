# = Hecks::Conventions::DispatchContract
#
# Runtime whitelist for .send() dispatch. Prevents arbitrary method
# invocation by validating that the target method is declared in the
# domain IR (commands, queries) or is a known CRUD builtin.
#
# Build the whitelist once at server boot, then validate every dispatch site.
#
#   whitelist = DispatchContract.build_whitelist(domain)
#   DispatchContract.validate!(whitelist, "Pizza", :create)  # => passes
#   DispatchContract.validate!(whitelist, "Pizza", :eval)    # => raises DispatchNotAllowed
#
module Hecks::Conventions
  # Hecks::Conventions::DispatchContract
  #
  # Runtime dispatch whitelist: validates .send() targets against declared commands, queries, and CRUD builtins.
  #
  module DispatchContract
    # Standard CRUD methods present on every generated aggregate class.
    CRUD_BUILTINS = %i[all find delete count update create].freeze

    # Raised when a dispatch target is not in the whitelist.
    class DispatchNotAllowed < SecurityError
      def initialize(agg_name, method_name)
        super("Dispatch not allowed: #{agg_name}##{method_name} is not a declared command, query, or CRUD builtin")
      end
    end

    # Build a whitelist from a domain IR.
    #
    # Keys are aggregate names (String), values are Sets of allowed method
    # Symbols (derived commands + queries + CRUD builtins).
    #
    # @param domain [Hecks::Domain] the parsed domain definition
    # @return [Hash{String => Set<Symbol>}] allowed methods per aggregate
    def self.build_whitelist(domain)
      domain.aggregates.each_with_object({}) do |agg, wl|
        allowed = Set.new(CRUD_BUILTINS)
        agg.commands.each do |cmd|
          allowed << Hecks::Conventions::CommandContract.method_name(cmd.name, agg.name)
        end
        agg.queries.each do |query|
          allowed << Hecks::Conventions::Names.bluebook_snake_name(query.name).to_sym
        end
        wl[agg.name.to_s] = allowed
      end
    end

    # Validate that a dispatch is allowed.
    #
    # @param whitelist [Hash{String => Set<Symbol>}] built by build_whitelist
    # @param agg_name [String, Symbol] aggregate name
    # @param method_name [Symbol, String] the method to be dispatched
    # @raise [DispatchNotAllowed] if the method is not in the whitelist
    # @return [void]
    def self.validate!(whitelist, agg_name, method_name)
      allowed = whitelist[agg_name.to_s]
      raise DispatchNotAllowed.new(agg_name, method_name) unless allowed
      raise DispatchNotAllowed.new(agg_name, method_name) unless allowed.include?(method_name.to_sym)
    end
  end
end

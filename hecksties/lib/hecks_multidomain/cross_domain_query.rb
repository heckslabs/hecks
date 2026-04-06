  # Hecks::CrossDomainQuery
  #
  # A read-only query that spans multiple bounded contexts. Registered at
  # the application level via +Hecks.cross_domain_query+, it resolves
  # aggregate classes from any booted domain using the +from+ helper.
  #
  # Cross-domain queries are the only sanctioned way to read data across
  # bounded context boundaries. They enforce read-only access -- mutations
  # must go through the owning domain's command bus.
  #
  # == Registration
  #
  #   Hecks.cross_domain_query "ComplianceCheck" do |model_id:|
  #     model   = from("ModelRegistry", "AiModel").find(model_id)
  #     reviews = from("Compliance", "ComplianceReview").by_model(model_id)
  #     { model: model, reviews: reviews }
  #   end
  #
  # == Execution
  #
  #   result = Hecks.query("ComplianceCheck", model_id: "abc")
  #   # => { model: #<AiModel>, reviews: [#<ComplianceReview>, ...] }
  #

module Hecks
  class CrossDomainQuery
    # @return [String] the registered name of this cross-domain query
    attr_reader :name

    # Creates a new cross-domain query with a name and execution block.
    #
    # The block is evaluated in a QueryContext, which provides the +from+
    # helper for resolving aggregate classes across domain boundaries.
    #
    # @param name [String] a unique name for this query (e.g., "ComplianceCheck")
    # @param block [Proc] the query logic; receives keyword arguments and has
    #   access to the +from+ helper via QueryContext
    def initialize(name, &block)
      @name = name
      @block = block
    end

    # Executes the cross-domain query with the given parameters.
    #
    # Creates a fresh QueryContext and evaluates the stored block within it,
    # passing the keyword arguments through.
    #
    # @param params [Hash] keyword arguments forwarded to the query block
    # @return [Object] whatever the query block returns
    def call(**params)
      context = QueryContext.new
      context.instance_exec(**params, &@block)
    end

    # Execution context that provides the +from+ helper for resolving
    # aggregate classes across domain boundaries. Each call to +call+
    # creates a fresh context to avoid state leakage between invocations.
    class QueryContext
      include HecksTemplating::NamingHelpers
      # Resolves an aggregate class from a named domain.
      #
      # Converts the domain and aggregate names to constants and looks them
      # up in the global namespace. The domain must already be booted.
      #
      # @param domain_name [String] the domain name (e.g., "ModelRegistry")
      # @param aggregate_name [String] the aggregate name (e.g., "AiModel")
      # @return [Class] the aggregate class (e.g., +ModelRegistryDomain::AiModel+)
      # @raise [NameError] if the domain or aggregate constant does not exist
      def from(domain_name, aggregate_name)
        mod_name = domain_module_name(domain_name)
        agg_name = domain_constant_name(aggregate_name)
        Object.const_get("#{mod_name}::#{agg_name}")
      end
    end
  end
end

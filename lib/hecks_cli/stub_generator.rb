
module Hecks
  class CLI < Thor
    # Hecks::CLI::StubGenerator
    #
    # Resolves a domain element by type and name, runs the appropriate code
    # generator, and returns a hash of { file_path => content } for writing.
    # Supports command, query, aggregate, workflow, service, policy, and
    # specification types.
    #
    #   gen = StubGenerator.new(domain, "command", "Withdraw")
    #   gen.generate  # => { "lib/banking_domain/account/commands/withdraw.rb" => "..." }
    #
    class StubGenerator
      include HecksTemplating::NamingHelpers
      # Initializes a StubGenerator for a specific element type and name.
      #
      # @param domain [BluebookModel::Structure::Domain] the domain to search in
      # @param type [String] the element type ("command", "query", "aggregate",
      #   "workflow", "service", "policy", "specification")
      # @param name [String] the element name to find (e.g., "Withdraw", "Pizza")
      def initialize(domain, type, name)
        @domain = domain
        @type = type
        @name = name
        @gem = domain.gem_name
        @mod = domain_module_name(domain.name)
      end

      # Generates stub files for the requested element.
      #
      # Dispatches to the appropriate generate_* method based on @type.
      # Returns nil if the type is unrecognized.
      #
      # @return [Hash<String, String>, nil] mapping of file paths to generated
      #   source code, or nil if type is unknown or element not found
      def generate
        case @type
        when "command"    then generate_command
        when "query"      then generate_query
        when "aggregate"  then generate_aggregate
        when "workflow"   then generate_workflow
        when "service"    then generate_service
        when "policy"     then generate_policy
        when "specification" then generate_specification
        end
      end

      private

      # Generates a command stub file.
      #
      # Finds the command in the domain, generates source using CommandGenerator,
      # and returns a single-entry hash of { path => source }.
      #
      # @return [Hash<String, String>, nil] the generated file, or nil if not found
      def generate_command
        agg, cmd, idx = find_command
        return error_not_found("command", @name) unless cmd
        event = agg.events[idx]
        safe = domain_constant_name(agg.name)
        snake = domain_snake_name(safe)
        src = gen(Generators::Domain::CommandGenerator, cmd,
                  domain_module: @mod, aggregate_name: safe, aggregate: agg, event: event)
        { path_for(snake, "commands", cmd.name) => src }
      end

      # Generates a query stub file.
      #
      # @return [Hash<String, String>, nil] the generated file, or nil if not found
      def generate_query
        agg, query = find_in_aggregates(:queries)
        return error_not_found("query", @name) unless query
        safe = domain_constant_name(agg.name)
        snake = domain_snake_name(safe)
        src = gen(Generators::Domain::QueryGenerator, query,
                  domain_module: @mod, aggregate_name: safe)
        { path_for(snake, "queries", query.name) => src }
      end

      # Generates a policy stub file.
      #
      # @return [Hash<String, String>, nil] the generated file, or nil if not found
      def generate_policy
        agg, policy = find_in_aggregates(:policies)
        return error_not_found("policy", @name) unless policy
        safe = domain_constant_name(agg.name)
        snake = domain_snake_name(safe)
        src = gen(Generators::Domain::PolicyGenerator, policy,
                  domain_module: @mod, aggregate_name: safe)
        { path_for(snake, "policies", policy.name) => src }
      end

      # Generates a specification stub file.
      #
      # @return [Hash<String, String>, nil] the generated file, or nil if not found
      def generate_specification
        agg, spec = find_in_aggregates(:specifications)
        return error_not_found("specification", @name) unless spec
        safe = domain_constant_name(agg.name)
        snake = domain_snake_name(safe)
        src = gen(Generators::Domain::SpecificationGenerator, spec,
                  domain_module: @mod, aggregate_name: safe)
        { path_for(snake, "specifications", spec.name) => src }
      end

      # Generates all files for an aggregate: the aggregate itself plus all commands.
      #
      # @return [Hash<String, String>, nil] mapping of all generated file paths
      #   to their source code, or nil if aggregate not found
      def generate_aggregate
        agg = @domain.aggregates.find { |a| a.name == @name }
        return error_not_found("aggregate", @name) unless agg
        safe = domain_constant_name(agg.name)
        snake = domain_snake_name(safe)
        files = {}
        files[path_for(snake, nil, agg.name)] =
          gen(Generators::Domain::AggregateGenerator, agg, domain_module: @mod)
        agg.commands.each_with_index do |cmd, i|
          files[path_for(snake, "commands", cmd.name)] =
            gen(Generators::Domain::CommandGenerator, cmd,
                domain_module: @mod, aggregate_name: safe, aggregate: agg, event: agg.events[i])
        end
        files
      end

      # Generates a workflow stub file.
      #
      # @return [Hash<String, String>, nil] the generated file, or nil if not found
      def generate_workflow
        wf = @domain.workflows.find { |w| w.name == @name }
        return error_not_found("workflow", @name) unless wf
        src = Generators::Domain::WorkflowGenerator.new(wf, domain_module: @mod).generate
        { "lib/#{@gem}/workflows/#{domain_snake_name(wf.name)}.rb" => src }
      end

      # Generates a service stub file.
      #
      # @return [Hash<String, String>, nil] the generated file, or nil if not found
      def generate_service
        svc = @domain.services.find { |s| s.name == @name }
        return error_not_found("service", @name) unless svc
        src = Generators::Domain::ServiceGenerator.new(svc, domain_module: @mod).generate
        { "lib/#{@gem}/services/#{domain_snake_name(svc.name)}.rb" => src }
      end

      # Finds a command by name across all aggregates.
      #
      # @return [Array(Aggregate, Command, Integer), nil] the containing aggregate,
      #   the command, and its index within the aggregate's commands; or nil
      def find_command
        @domain.aggregates.each do |agg|
          agg.commands.each_with_index do |cmd, i|
            return [agg, cmd, i] if cmd.name == @name
          end
        end
        nil
      end

      # Finds an element by name in a named collection across all aggregates.
      #
      # @param collection [Symbol] the collection method name (e.g., :queries, :policies)
      # @return [Array(Aggregate, Object)] the containing aggregate and the found item,
      #   or [nil, nil] if not found
      def find_in_aggregates(collection)
        @domain.aggregates.each do |agg|
          item = agg.send(collection).find { |x| x.name == @name }
          return [agg, item] if item
        end
        [nil, nil]
      end

      # Shorthand for instantiating a generator and calling #generate.
      #
      # @param klass [Class] the generator class
      # @param obj [Object] the domain element to generate from
      # @param opts [Hash] additional keyword arguments for the generator
      # @return [String] the generated source code
      def gen(klass, obj, **opts) = klass.new(obj, **opts).generate

      # Builds a file path for a generated stub.
      #
      # @param agg_snake [String] the underscore aggregate name
      # @param subdir [String, nil] optional subdirectory (e.g., "commands", "queries")
      # @param name [String] the element name
      # @return [String] the relative file path
      def path_for(agg_snake, subdir, name)
        snake_name = domain_snake_name(domain_constant_name(name))
        parts = ["lib", @gem, agg_snake]
        parts << subdir if subdir
        parts << "#{snake_name}.rb"
        File.join(*parts)
      end

      # Reports an element-not-found error to stderr.
      #
      # @param type [String] the element type that was not found
      # @param name [String] the element name that was not found
      # @return [nil] always returns nil
      def error_not_found(type, name)
        $stderr.puts "No #{type} '#{name}' found in #{@domain.name}"
        nil
      end
    end
  end
end

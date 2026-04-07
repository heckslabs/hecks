Hecks::Chapters.load_aggregates(
  Hecks::Chapters::Bluebook::GeneratorInternalsParagraph,
  base_dir: File.expand_path("command_generator", __dir__)
)

module Hecks
  module Generators
    module Domain
    # Hecks::Generators::Domain::CommandGenerator
    #
    # Generates command classes with an emits declaration and a call method.
    # Create commands build a new aggregate; update commands look up an
    # existing one by ID and merge changed attributes. Handles Ruby keyword-
    # safe attribute names via **kwargs. The Hecks::Command mixin (included
    # at load time) provides event emission and handler wiring. Part of
    # Generators::Domain, consumed by DomainGemGenerator and InMemoryLoader.
    #
    # == Create vs. Update Detection
    #
    # A command is classified as an "update" if it has an attribute matching
    # the aggregate's ID pattern (e.g., +pizza+ for a Pizza aggregate).
    # The self-reference is found by +find_self_ref+, which checks
    # snake_case name first, then progressively shorter suffixes. If no ID
    # attribute is found, the command is classified as a "create".
    #
    # == Generated Structure
    #
    # The generated class is nested under +Aggregate::Commands+ and includes:
    # - +include Hecks::Command+ for event emission and handler wiring
    # - +emits "EventName"+ declaration if an event is associated
    # - +attr_reader+ declarations for all command attributes
    # - An +initialize+ method (keyword params or +**kwargs+ for keyword-safe names)
    # - A +call+ method that either creates a new aggregate or updates an existing one
    #
    # == Usage
    #
    #   gen = CommandGenerator.new(cmd, domain_module: "PizzasDomain",
    #     aggregate_name: "Pizza", aggregate: agg, event: evt)
    #   gen.generate
    #
    class CommandGenerator < Hecks::Generator
      include InjectionHelpers

      # Initializes the command generator.
      #
      # @param command [Hecks::DomainModel::Behavior::Command] the command model object;
      #   provides +name+, +attributes+, +preconditions+, +postconditions+, +call_body+, and +sets+
      # @param domain_module [String] the Ruby module name to wrap the generated class in
      # @param aggregate_name [String] the name of the parent aggregate class (e.g., "Pizza")
      # @param aggregate [Hecks::DomainModel::Structure::Aggregate, nil] the aggregate model object,
      #   used to map command attributes to aggregate constructor args; nil if not available
      # @param event [Object, nil] the associated domain event; if present, an +emits+ declaration
      #   is added and the +call+ method constructs the aggregate
      def initialize(command, domain_module:, aggregate_name:, aggregate: nil, event: nil, mixin_prefix: "Hecks")
        @command = command
        @domain_module = domain_module
        @aggregate_name = aggregate_name
        @aggregate = aggregate
        @event = event
        @mixin_prefix = mixin_prefix
        @has_keyword_attrs = @command.attributes.any? { |attr| Hecks::Utils.ruby_keyword?(attr.name) }
        agg_snake = domain_snake_name(aggregate_name)
        @self_ref = find_self_ref(agg_snake)
        @is_create = @self_ref.nil?
      end

      # Generates the full Ruby source code for the command class.
      #
      # @return [String] the generated Ruby source code, newline-terminated
      def generate
        lines = []
        lines << "module #{@domain_module}"
        lines << "  class #{@aggregate_name}"
        lines << "    module Commands"
        lines << "      class #{@command.name}"
        lines << "        include #{@mixin_prefix}::#{@mixin_prefix == "Hecks" ? "Command" : "Runtime::Command"}"
        if @event
          event_names = Array(@command.emits).any? ? Array(@command.emits) : [@event.name]
          if event_names.length == 1
            lines << "        emits \"#{event_names.first}\""
          else
            names_str = event_names.map { |name| "\"#{name}\"" }.join(", ")
            lines << "        emits #{names_str}"
          end
        end
        lines.concat(condition_declarations)
        lines << ""
        attr_syms = @command.attributes.map { |attr| ":#{attr.name}" } +
                    (@command.references || []).map { |ref| ":#{ref.name}" }
        if attr_syms.size <= 2
          lines << "        attr_reader #{attr_syms.join(", ")}"
        else
          attr_syms.each { |sym| lines << "        attr_reader #{sym}" }
        end
        lines << ""
        lines.concat(initializer_lines)
        lines << ""
        if @command.call_body
          lines.concat(custom_call_lines)
        elsif @aggregate && @event
          lines.concat(call_lines)
        end
        lines << "      end"
        lines << "    end"
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end

      private

      # Generates comment lines for preconditions and postconditions.
      #
      # @return [Array<String>] comment lines prefixed with "# precondition:" or "# postcondition:",
      #   or an empty array if no conditions are defined
      def condition_declarations
        conds = @command.preconditions.map { |cond| "        # precondition: #{cond.message}" } +
                @command.postconditions.map { |cond| "        # postcondition: #{cond.message}" }
        conds.any? ? [""] + conds : []
      end

      # Generates lines for a custom +call+ method using the command's DSL-provided block.
      #
      # @return [Array<String>] lines of Ruby source code for the custom call method
      def custom_call_lines
        source = Hecks::Utils.block_source(@command.call_body)
        lines = ["        def call"]
        source.split("\n").each { |line| lines << "          #{line}" }
        lines << "        end"
        lines
      end

      # Generates the +initialize+ method lines.
      #
      # Uses +**kwargs+ when any attribute name is a Ruby keyword; otherwise uses
      # named keyword parameters with multi-line formatting for 3+ params.
      #
      # @return [Array<String>] lines of Ruby source code for the initialize method
      def initializer_lines
        lines = []
        if @has_keyword_attrs
          lines << "        def initialize(**kwargs)"
          @command.attributes.each do |attr|
            lines << "          @#{attr.name} = kwargs[:#{attr.name}]"
          end
          (@command.references || []).each do |ref|
            lines << "          @#{ref.name} = kwargs[:#{ref.name}]"
          end
        else
          params = constructor_params
          if params.size <= 2
            lines << "        def initialize(#{params.join(", ")})"
          else
            lines << "        def initialize("
            params.each_with_index do |param, idx|
              suffix = idx < params.size - 1 ? "," : ""
              lines << "          #{param}#{suffix}"
            end
            lines << "        )"
          end
          @command.attributes.each do |attr|
            lines << "          @#{attr.name} = #{attr.name}"
          end
          (@command.references || []).each do |ref|
            lines << "          @#{ref.name} = #{ref.name}"
          end
        end
        lines << "        end"
        lines
      end

      # Generates the standard +call+ method that either creates or updates an aggregate.
      #
      # @return [Array<String>] lines of Ruby source code for the call method
      def call_lines
        lines = []
        lines << "        def call"
        if @is_create
          lines.concat(create_body)
        else
          lines.concat(update_body)
        end
        lines << "        end"
        lines
      end

      # Generates the body of a create command's +call+ method.
      #
      # Constructs a new aggregate instance with attributes mapped from the command.
      #
      # @return [Array<String>] lines of Ruby source for the Aggregate.new(...) call
      def create_body
        args = create_constructor_args
        format_new_call("          ", args)
      end

      # Generates the body of an update command's +call+ method.
      #
      # Looks up an existing aggregate by ID, applies lifecycle guards if applicable,
      # and constructs a new aggregate instance merging existing and changed attributes.
      # Raises +Hecks::Error+ if the entity is not found.
      #
      # @return [Array<String>] lines of Ruby source for the find-and-update logic
      def update_body
        lines = []
        ref = @self_ref
        if ref
          lines << "          _ref_val = #{ref.name}"
          lines << "          _lookup_id = _ref_val.respond_to?(:id) ? _ref_val.id : _ref_val"
          lines << "          existing = repository.find(_lookup_id)"
          lines << "          if existing"
          lines.concat(lifecycle_guard_lines("            "))
          lines.concat(format_new_call("            ", update_constructor_args))
          lines << "          else"
          lines << "            raise #{@domain_module}::Error, \"#{@aggregate_name} not found: \#{_lookup_id}\""
          lines << "          end"
        else
          lines.concat(format_new_call("          ", create_constructor_args))
        end
        lines
      end

      # create_constructor_args, update_constructor_args, agg_attrs
      # are in InjectionHelpers

      # Format Aggregate.new(...) -- inline if <=2 args, stacked otherwise.
      #
      # @param indent [String] the whitespace prefix for each line
      # @param args [Array<String>] the keyword argument strings
      # @return [Array<String>] formatted lines for the Aggregate.new call
      def format_new_call(indent, args)
        if args.size <= 2
          ["#{indent}#{@aggregate_name}.new(#{args.join(", ")})"]
        else
          lines = ["#{indent}#{@aggregate_name}.new("]
          args.each_with_index do |arg, idx|
            comma = idx < args.size - 1 ? "," : ""
            lines << "#{indent}  #{arg}#{comma}"
          end
          lines << "#{indent})"
          lines
        end
      end


      # Builds keyword parameter strings for the command's constructor.
      #
      # @return [Array<String>] parameter strings with nil defaults (e.g., ["name: nil", "size: nil"])
      def constructor_params
        @command.attributes.map { |attr| "#{attr.name}: nil" } +
        (@command.references || []).map { |ref| "#{ref.name}: nil" }
      end

      # Find a self-referencing reference on this command.
      # A self-ref is a reference whose target type matches the aggregate.
      def find_self_ref(agg_snake)
        (@command.references || []).find do |ref|
          Hecks::Utils.underscore(ref.type) == agg_snake
        end
      end
    end
    end
  end
end

require_relative "errors"

module Hecks
  module Runtime
    # Finds the one adapter this boot loaded for a port name.
    #
    # Shared by the port-operation interpreter (an aggregate asking out) and the query interpreter
    # (a query answered by a port), so both refuse the same way when nothing, or too much,
    # implements the port.
    module AdapterLookup
      @stand_in = nil

      module_function

      # Modules whose instance methods every object inherits; a method they own answers no query.
      INHERITED_OWNERS = [Object, Kernel, BasicObject].freeze

      # Answers every port with a stand-in instead of its adapter while the block runs, for a
      # caller that must not reach what the adapters reach (the fuzzer replays a domain whose
      # adapters run shells and write files). Boot still checks the real adapters' classes; only
      # what `call` hands out changes.
      #
      # @param stand_in [#call] answers `(port_name, asked)` with the object to ask instead
      # @yield the work to run with the stand-in in place
      # @return [Object] what the block answers
      def standing_in(stand_in)
        previous = @stand_in
        @stand_in = stand_in
        yield
      ensure
        @stand_in = previous
      end

      # @param registry [Runtime::Registry] the booted registry whose adapters are searched
      # @param port_name [String] the port's name as an adapter declares it
      # @param asked [String] what is being asked, worded into a refusal
      # @return [Object] a new instance of the port's only adapter, or the stand-in for it
      # @raise [Runtime::WiringError] if no adapter, or more than one, implements the port
      def call(registry, port_name, asked:)
        adapter_class(registry, port_name, asked: asked)
        return @stand_in.call(port_name, asked) if @stand_in

        adapter_class(registry, port_name, asked: asked).new
      end

      # Finds the class of the one adapter this boot loaded for a port name, without building it,
      # so boot can check what the adapter answers before anything asks it.
      #
      # @param registry [Runtime::Registry] the booted registry whose adapters are searched
      # @param port_name [String] the port's name as an adapter declares it
      # @param asked [String] what is being asked, worded into a refusal
      # @return [Class] the port's only adapter
      # @raise [Runtime::WiringError] if no adapter, or more than one, implements the port
      def adapter_class(registry, port_name, asked:)
        implementations = registry.adapters.values.select { |adapter| adapter.port == port_name }

        case implementations.size
        when 1 then Adapters.const_get(implementations.first.name)
        when 0 then raise WiringError, "no adapter implements the #{port_name} port — nothing can answer #{asked}"
        else raise WiringError,
                   "#{implementations.size} adapters implement the #{port_name} port " \
                   "(#{implementations.map(&:name).sort.join(", ")}) — the runtime will not choose for you"
        end
      end

      # Checks that an adapter class can be built with a bare `.new` and answers a query: it
      # defines the method itself (not inherited from Object or Kernel, so a query named `hash` or
      # `display` is not answered by them) and takes exactly the query's arguments as keywords.
      #
      # @param klass [Class] the adapter class {adapter_class} found
      # @param port_name [String] the port's name, worded into a refusal
      # @param method [String] the snake-cased query name the adapter is asked by
      # @param query [Bluebook::Query] the declared query whose arguments the method must take
      # @param asked [String] what is being asked, worded into a refusal
      # @return [void]
      # @raise [Runtime::WiringError] if the constructor needs arguments, the method is missing or
      #   inherited, or its keywords do not match the query's arguments
      def check_answers!(klass, port_name, method, query, asked:)
        required = klass.instance_method(:initialize).parameters.filter_map { |kind, name| name if %i[req keyreq].include?(kind) }
        unless required.empty?
          raise WiringError, "#{klass} implements the #{port_name} port but its constructor requires " \
                             "#{required.join(", ")} — it is built with no arguments"
        end

        unless klass.public_method_defined?(method) &&
               !INHERITED_OWNERS.include?(klass.public_instance_method(method).owner)
          raise WiringError, "#{klass} implements the #{port_name} port but not ##{method}, " \
                             "which answers #{asked}"
        end

        check_keywords!(klass, method, query, asked)
      end

      # @raise [Runtime::WiringError] if the method takes a positional argument, requires a keyword
      #   the query does not require, or accepts none of a declared argument
      def check_keywords!(klass, method, query, asked)
        parameters = klass.public_instance_method(method).parameters
        wanted     = query.attributes.map { |attribute| attribute.name.to_sym }
        required   = query.attributes.reject(&:optional?).map { |attribute| attribute.name.to_sym }
        problems   = keyword_problems(parameters, wanted, required)
        return if problems.empty?

        raise WiringError, "#{klass}##{method} answers #{asked} but #{problems.join(" and ")} — it is asked " \
                           "with keywords for the query's arguments (#{wanted.empty? ? "none" : wanted.join(", ")})"
      end

      # @return [Array<String>] how `parameters` fails to take exactly the `wanted` keywords
      def keyword_problems(parameters, wanted, required)
        kinds   = parameters.map(&:first)
        taken   = parameters.select { |kind, _| kind.to_s.start_with?("key") && kind != :keyrest }.map(&:last)
        missing = kinds.include?(:keyrest) ? [] : wanted - taken
        extra   = parameters.select { |kind, name| kind == :keyreq && !required.include?(name) }.map(&:last)
        [("takes positional arguments" if kinds.intersect?(%i[req opt rest])),
         keyword_problem("does not take", missing),
         keyword_problem("requires", extra, ", which the query does not")].compact
      end

      # @return [String, nil] a phrase naming `names` as keywords, or nil when there are none
      def keyword_problem(verb, names, suffix = "")
        "#{verb} #{names.map { |name| "#{name}:" }.join(", ")}#{suffix}" unless names.empty?
      end
    end
  end
end

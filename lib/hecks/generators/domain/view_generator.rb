module Hecks
  module Generators
    module Domain
    # Hecks::Generators::Domain::ViewGenerator
    #
    # Generates CQRS view (read model) classes that subscribe to domain events
    # and maintain projected state. Views are namespaced under +Domain::Views+.
    #
    # Each view class includes:
    # - A +PROJECTIONS+ constant listing the event names it handles
    # - A +call(event, state)+ method that dispatches to the appropriate
    #   +project_<event_name>+ method based on the event's class name
    # - Individual +project_<event_name>+ methods whose bodies come from
    #   the DSL projection blocks
    #
    # The +call+ method uses the event's class name (underscore-cased) to find
    # the matching projection method. If no projection handles the event, the
    # current state is returned unchanged.
    #
    # Part of Generators::Domain.
    #
    # == Usage
    #
    #   gen = ViewGenerator.new(view, domain_module: "ComplianceDomain")
    #   gen.generate
    #
    class ViewGenerator < Hecks::Generator

      # Initializes the view generator.
      #
      # @param view [Object] the view model object; provides +name+ and +projections+
      #   (a Hash or array of hashes mapping event names to projection blocks)
      # @param domain_module [String] the Ruby module name to wrap the generated class in
      def initialize(view, domain_module:)
        @view = view
        @domain_module = domain_module
      end

      # Generates the full Ruby source code for the view class.
      #
      # Produces a class under +Domain::Views+ with a +PROJECTIONS+ constant,
      # a +call+ dispatcher method, and individual +project_<event>+ methods
      # for each projection.
      #
      # @return [String] the generated Ruby source code, newline-terminated
      def generate
        lines = []
        lines << "module #{@domain_module}"
        lines << "  module Views"
        lines << "    class #{@view.name}"
        projections = @view.projections.is_a?(Hash) ? @view.projections : @view.projections.to_h { |p| [p[:event_name], p[:block]] }
        proj_names = projections.keys
        lines << "      PROJECTIONS = %w[#{proj_names.join(' ')}].freeze unless defined?(PROJECTIONS)"
        lines << ""
        lines << "      attr_reader :state"
        lines << ""
        lines << "      def call(event, state = {})"
        lines << "        name = event.class.name.split('::').last"
        lines << "        method = :\"project_\#{domain_snake_name(name)}\""
        lines << "        @state = respond_to?(method) ? send(method, event, state) : state"
        lines << "        self"
        lines << "      end"
        projections.each do |event_name, block|
          method_name = domain_snake_name(event_name)
          body = Hecks::Utils.block_source(block)
          lines << ""
          lines << "      def project_#{method_name}(event, state)"
          lines << "        #{body}"
          lines << "      end"
        end
        lines << "    end"
        lines << "  end"
        lines << "end"
        lines.join("\n") + "\n"
      end
    end
    end
  end
end

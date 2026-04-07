module Hecks
  class Workshop
    # Hecks::Workshop::CommandHandle
    #
    # Interactive handle for adding attributes to a command after creation.
    # Returned by AggregateHandle when a bare command name is used in the
    # one-line REPL syntax, enabling chained attribute additions.
    #
    # Part of the Session layer -- enables the dot-syntax REPL workflow:
    #
    #   Post.create              # returns CommandHandle
    #   Post.create.title String # adds attribute, prints feedback
    #
    class CommandHandle
      # @param command_name [String] PascalCase command name (e.g. "CreatePost")
      # @param builder [DSL::AggregateBuilder] the parent aggregate builder
      # @param aggregate_name [String] the aggregate name for feedback messages
      def initialize(command_name, builder, aggregate_name)
        @command_name = command_name
        @builder = builder
        @aggregate_name = aggregate_name
      end

      # Add an attribute to the command via implicit syntax.
      #
      #   Post.create.title String
      #   # => "title attribute added to CreatePost"
      #
      # @param name [Symbol] the attribute name
      # @param args [Array] first arg is the type (Class or String)
      # @param kwargs [Hash] additional options
      # @return [CommandHandle] self, for chaining
      def method_missing(name, *args, **kwargs, &block)
        if args.first.is_a?(Class) || (args.first.is_a?(String) && args.first =~ /\A[A-Z]/)
          add_attribute(name, args.first, **kwargs)
        elsif args.first.is_a?(Hash) && (args.first[:reference] || args.first[:list])
          add_attribute(name, args.first, **kwargs)
        else
          super
        end
      end

      def respond_to_missing?(name, include_private = false)
        true
      end

      # @return [String] compact representation
      def inspect
        "#<#{@command_name} command on #{@aggregate_name}>"
      end

      # Add a reference to the command.
      def reference_to(type, role: nil)
        cmd = find_command
        return self unless cmd
        type_str = type.to_s
        parts = type_str.split("::")
        target = parts.last
        domain = parts.length > 1 ? parts[0..-2].join("::") : nil
        name = (role || target.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                               .gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase).to_sym
        ref = DomainModel::Structure::Reference.new(name: name, type: target, domain: domain)
        cmd.references << ref
        puts "reference_to #{type} added to #{@command_name}"
        self
      end

      private

      # Add an attribute to the underlying command and print feedback.
      def add_attribute(name, type, **kwargs)
        cmd = find_command
        return self unless cmd

        list = type.is_a?(Hash) && type[:list]
        actual_type = type.is_a?(Hash) ? type.values.first : type

        attr = DomainModel::Structure::Attribute.new(
          name: name.to_sym, type: actual_type,
          list: !!list, **kwargs
        )
        cmd.attributes << attr
        event_name = cmd.inferred_event_name
        puts "#{name} attribute added to #{@command_name} -> #{event_name}"
        self
      end

      # Find the command object in the builder's commands array.
      def find_command
        @builder.commands.find { |c| c.name == @command_name }
      end
    end
  end
end

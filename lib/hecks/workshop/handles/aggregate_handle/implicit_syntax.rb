# Hecks::Workshop::AggregateHandle::ImplicitSyntax
#
# method_missing-based one-line dot syntax for the REPL.
# Enables: Post.title String, Post.create, Post.Address { ... }
#
module Hecks
  class Workshop
    class AggregateHandle
      module ImplicitSyntax
        def method_missing(name, *args, **kwargs, &block)
          name_s = name.to_s

          if name_s =~ /\A[A-Z]/ && block_given?
            value_object(name_s, &block)
          elsif block_given?
            command(infer_command_name(name_s), &block)
          elsif type_argument?(args.first)
            attr(name, args.first, **kwargs)
          elsif args.empty? && kwargs.empty? && !block_given?
            cmd_name = infer_command_name(name_s)
            command(cmd_name) unless @command_handles.key?(cmd_name)
            @command_handles[cmd_name] ||= CommandHandle.new(cmd_name, @builder, @name)
          else
            super
          end
        end

        def respond_to_missing?(name, include_private = false)
          true
        end

        private

        def type_argument?(arg)
          return false unless arg
          arg.is_a?(Class) ||
            (arg.is_a?(String) && arg =~ /\A[A-Z]/) ||
            (arg.respond_to?(:key?) && (arg.key?(:list) || arg.key?(:reference)))
        end
      end
    end
  end
end

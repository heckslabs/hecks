  # BlueBook::Grammar
  #
  # The domain command language grammar. Parses input strings into structured
  # command hashes. Defines what's expressible — bare commands, aggregate
  # creation, handle methods with typed arguments.
  #
  #   BlueBook::Grammar.parse("Pizza.attr :name, String")
  #   # => { target: "Pizza", method: "attr", args: [:name, String], kwargs: {} }
  #
  #   BlueBook::Grammar.parse("describe")
  #   # => { target: nil, method: "describe", args: [], kwargs: {} }
  #
module BlueBook
  module Grammar
    BARE_COMMANDS = %w[
      describe browse validate preview status aggregates diagram
      play! sketch! reset! reload! events history save to_dsl
    ].freeze

    HANDLE_METHODS = begin
      dsl_methods = (Hecks::DSL::AggregateBuilder.public_instance_methods -
                     Object.public_instance_methods).map(&:to_s)
      crud = %w[create new all find count]
      introspection = %w[describe preview errors valid?]
      # attr: shorthand for attribute used in workshop handles
      # transition: lifecycle sub-DSL method used directly at aggregate level
      workshop_aliases = %w[attr transition]
      remove_ops = %w[remove remove_command remove_event remove_policy remove_validation
                      remove_query remove_scope remove_specification remove_subscriber
                      remove_value_object remove_entity]
      (dsl_methods + crud + introspection + workshop_aliases + remove_ops).uniq.freeze
    end

    TYPE_MAP = {
      "String" => String, "Integer" => Integer, "Float" => Float,
      "TrueClass" => TrueClass, "Date" => Date, "DateTime" => DateTime,
      "JSON" => "JSON", "Boolean" => TrueClass
    }.freeze

    # Parse an input string into a command hash.
    # Returns { target:, method:, args:, kwargs: } or { error: }
    def self.parse(input)
      input = input.strip
      return { error: "Empty command" } if input.empty?

      if BARE_COMMANDS.include?(input)
        return { target: nil, method: input, args: [], kwargs: {} }
      end

      target, dot, rest = input.partition(".")
      return { error: "Unknown command: #{input}" } unless target.match?(/\A[A-Z][a-zA-Z0-9]*\z/)

      if dot.empty?
        return { target: target, method: nil, args: [], kwargs: {} }
      end

      # Handle parens: create_gunslinger(name: "x") or create_gunslinger()
      if rest =~ /\A(\w+[!?]?)\((.*)\)\s*\z/m
        method_name = $1
        arg_str = $2
      else
        method_name, _, arg_str = rest.partition(/\s+/)
        method_name = method_name.strip
      end

      blocked = %w[send class eval instance_eval instance_variable_get instance_variable_set
                   const_get const_set method system exec fork spawn require load
                   open read write delete unlink chmod chown public_send __send__
                   define_method remove_method undef_method boot configure]
      unless HANDLE_METHODS.include?(method_name) || (method_name.match?(/\A[a-z][a-z0-9_]*[!?]?\z/) && !blocked.include?(method_name))
        return { error: "Unknown method: #{target}.#{method_name}" }
      end

      args, kwargs = parse_args(arg_str.strip)
      { target: target, method: method_name, args: args, kwargs: kwargs }
    end

    # Parse an argument string into positional args and keyword args.
    def self.parse_args(str)
      return [[], {}] if str.empty?
      args = []
      kwargs = {}
      Tokenizer.tokenize(str).each do |token|
        case token
        when /\A:(\w+)\z/
          args << $1.to_sym
        when /\A"(.*)"\z/
          args << $1
        when /\Areference_to\("(.+)"\)\z/
          args << { reference: $1 }
        when /\Alist_of\("(.+)"\)\z/
          args << { list: $1 }
        when /\A(\w+):\s*"(.*)"\z/
          kwargs[$1.to_sym] = $2
        when /\A(\w+):\s*true\z/
          kwargs[$1.to_sym] = true
        when /\A(\w+):\s*false\z/
          kwargs[$1.to_sym] = false
        when /\A(\w+):\s*(\d+)\z/
          kwargs[$1.to_sym] = $2.to_i
        when /\A"(.+)"\s*=>\s*"(.+)"\z/
          args << { $1 => $2 }
        else
          args << TYPE_MAP[token] if TYPE_MAP.key?(token)
        end
      end
      [args, kwargs]
    end
  end
end

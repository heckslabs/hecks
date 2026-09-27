require_relative "bootstrap_table"

module Hecks
  module Bluebook
    module DSL
      # Executes a grammar-admitted (context, word) pair straight off the DSL's own table when
      # its row matches one of a few verified-safe shapes; anything else falls through unchanged.
      module GenericDispatch
        NOT_HANDLED = Object.new.freeze

        COERCE_BY_KIND = { "text" => :to_s, "symbol" => :to_sym }.freeze

        # Not derivable from `fills:` (these rows all carry `fills: ""`) — the append target
        # for each opens-block word must be named here explicitly.
        SAFE_OPENS_BLOCK = {
          %w[Bluebook policy]          => :policies,
          %w[Bluebook process_manager] => :process_managers,
          %w[Bluebook read_model]      => :read_models
        }.freeze

        # Consulted only while `MetaValidator.bootstrapping?`, before the real grammar table
        # exists to read `calls:` from; every row is carried since carrying them costs nothing.
        BOOTSTRAP_CALLS_FALLBACK = BootstrapTable::CALLS

        module_function

        # Whether `try` would execute this (context, word) pair, without executing anything.
        def handles?(context, word, rows: MetaValidator::SyntaxBoot.call)
          !shape_for(context, word, rows).nil?
        end

        # Executes a table-admitted word via the shape `shape_for` found for it, or returns
        # NOT_HANDLED so the caller can fall back to its own "not yet implemented" refusal.
        def try(builder, context, word, args, kwargs, block, rows)
          shape = shape_for(context, word, rows)
          return NOT_HANDLED unless shape

          case shape[:kind]
          when :calls_through then try_calls_through(builder, shape[:calls], args, kwargs, block)
          when :opens_block   then try_opens_block(builder, shape[:keyword], args, kwargs, block)
          when :zero_arg      then try_zero_arg(builder, shape[:keyword], args)
          when :single_fill   then try_single_fill(builder, shape[:fills], shape[:argument], args, kwargs)
          else
            # Backstop: `shape_for` names exactly four kinds; falling through would return nil,
            # which the caller reads as "handled", silently turning the word into a no-op.
            raise Runtime::WiringError,
                  "no dispatcher handles shape #{shape[:kind].inspect} — add one before shape_for can produce it"
          end
        end

        # Classifies a (context, word) pair into one of the four table-executable shapes, or
        # nil when it falls outside this module's verified scope.
        #
        # Early-return chain: each check depends on locals from the ones before it, read once
        # top-to-bottom; splitting per shape would just re-thread the same locals across methods.
        # rubocop:disable-next Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def shape_for(context, word, rows)
          keyword = rows[:keywords].find { |k| k[:context] == context && k[:word] == word && k[:status] != "retired" }
          return nil unless keyword

          calls = keyword[:calls].to_s
          return { kind: :calls_through, calls: calls } unless calls.empty?

          return { kind: :opens_block, keyword: keyword } if SAFE_OPENS_BLOCK.key?([context, word])

          fills = keyword[:fills].to_s
          return nil if fills.empty?

          arguments = rows[:arguments].select { |a| a[:context] == context && a[:keyword] == word && a[:status] != "retired" }
          return { kind: :zero_arg, keyword: keyword } if arguments.empty?

          return nil unless arguments.size == 1

          arg = arguments.first
          return nil if arg[:variadic] == "true" || arg[:at] != "1" || !arg[:named].to_s.empty?
          return nil unless COERCE_BY_KIND.key?(arg[:kind])

          { kind: :single_fill, fills: fills, argument: arg }
        end

        # Forwards a word's whole call, unchanged, to the builder method its row's `calls:`
        # names — no argument-shape interpretation; the target method already does its own.
        def try_calls_through(builder, calls, args, kwargs, block)
          builder.send(calls, *args, **kwargs, &block)
        end

        # Builds a child construct from a block-opening word and appends it to the builder's
        # list named by its row in `SAFE_OPENS_BLOCK`.
        def try_opens_block(builder, keyword, args, kwargs, block)
          return NOT_HANDLED unless kwargs.empty?

          target_ivar = SAFE_OPENS_BLOCK.fetch([keyword[:context], keyword[:word]])
          child_class = DSL.const_get("#{keyword[:opens]}Builder")

          raise ArgumentError, "wrong number of arguments (given #{args.size}, expected 1)" unless args.size == 1

          child = child_class.build(args.first, &block)

          ivar = :"@#{target_ivar}"
          list = builder.instance_variable_get(ivar) || builder.instance_variable_set(ivar, [])
          list << child
        end

        # Stores a zero-argument word's value into the instance variable its row's `fills:` names.
        def try_zero_arg(builder, keyword, args)
          raise ArgumentError, "wrong number of arguments (given #{args.size}, expected 0)" unless args.empty?

          rows = MetaValidator::SyntaxBoot.call[:keywords]
          siblings = rows.count do |k|
            k[:context] == keyword[:context] && k[:fills] == keyword[:fills] && k[:status] != "retired"
          end
          value = siblings > 1 ? keyword[:word].to_sym : true

          builder.instance_variable_set(:"@#{keyword[:fills]}", value)
        end

        # Coerces a word's one positional argument and stores it, appending when the target
        # ivar already holds an Array and assigning otherwise.
        def try_single_fill(builder, fills, arg, args, kwargs)
          return NOT_HANDLED unless kwargs.empty?

          coerce = COERCE_BY_KIND.fetch(arg[:kind])

          raise ArgumentError, "wrong number of arguments (given #{args.size}, expected 1)" unless args.size == 1

          value = arg[:coerce] == "false" ? args.first : args.first.public_send(coerce)

          message = arg[:blank_message].to_s
          raise Malformed, message if !message.empty? && value.to_s.empty?

          ivar = :"@#{fills}"
          current = builder.instance_variable_get(ivar)

          if current.is_a?(Array)
            current << value
          else
            builder.instance_variable_set(ivar, value)
          end
        end
      end
    end
  end
end

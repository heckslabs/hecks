require "json"
require_relative "handle"
require_relative "command_request"
require_relative "../naming"
require_relative "../runtime/errors"
require_relative "../runtime/value"

module Hecks
  module Doors
    # The JSON door: translates URL segments and parsed JSON bodies to and from the facade.
    # No HTTP lives here; every miss raises `Runtime::NotFound`, distinguished by message.
    module JsonDoor
      module_function

      # Resolves a domain name and an aggregate name, as two URL segments carry them, to
      # that aggregate's door.
      #
      # The name is checked against the current boot's IR before Ruby's constant table, so
      # a stale same-named constant from an earlier boot is never returned.
      #
      # @param dispatcher [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted dispatcher
      # @param domain [String, Symbol] the chapter name, such as `"Banking"`
      # @param name [String, Symbol] the aggregate's declared name, such as `"Customer"`
      # @return [Module] the aggregate door installed at `domain::name`
      # @raise [Runtime::NotFound] if the chapter or its aggregate is not declared
      # @raise [NameError] if the aggregate has no facade constant (`install_doors: false`)
      def aggregate(dispatcher, domain, name)
        ir = dispatcher.registry.bluebook(domain)&.aggregate(name)
        raise Runtime::NotFound, "#{domain} declares no aggregate named #{name.inspect}" unless ir

        Object.const_get("#{domain}::#{ir.hecks_name}")
      end

      # Names the door method that creates a record of this aggregate: the first command
      # it declares that `creates?`, spelled as a Ruby caller would (`"create_pizza!"`).
      #
      # @param klass [Module] an aggregate door, as `aggregate` returns
      # @return [String] the method name to `public_send` to the door
      # @raise [Runtime::NotFound] if the aggregate declares no creating command
      def creating_command(klass)
        creating = klass.ir.commands.find(&:creates?)
        raise Runtime::NotFound, "#{klass.ir.hecks_name} declares no creating command" unless creating

        "#{Naming.snake(creating.hecks_name)}!"
      end

      # Confirms that a command name arriving as text is one a `Handle` of this aggregate
      # answers, before a caller `public_send`s it.
      #
      # A `Handle` defines only the non-creating commands, so the creating command is
      # rejected here rather than failing later as a raw `NoMethodError`.
      #
      # @param klass [Module] an aggregate door, as `aggregate` returns
      # @param name [String, Symbol] the wanted method name with its bang, such as
      #   `"add_topping!"`
      # @return [String] `name` as a String, unchanged, when a `Handle` answers it
      # @raise [Runtime::NotFound] if no non-creating command has that method name
      def validate_command!(klass, name)
        wanted = name.to_s
        dispatchable = klass.ir.commands.reject(&:creates?).map { |command| "#{Naming.snake(command.hecks_name)}!" }
        return wanted if dispatchable.include?(wanted)

        raise Runtime::NotFound, "#{klass.ir.hecks_name} declares no command named #{wanted.inspect}"
      end

      # Fetches one record by id, raising instead of answering nil on a miss.
      #
      # @param klass [Module] an aggregate door, as `aggregate` returns
      # @param id [String] the record's identity, as the URL carried it
      # @return [Doors::Handle] the record in hand
      # @raise [Runtime::NotFound] if the repository holds no record with that id
      def find!(klass, id)
        klass.find(id) or raise Runtime::NotFound, "no #{klass.ir.hecks_name} found for id #{id.inspect}"
      end

      # Converts every Hash key to a Symbol, at every depth of a parsed JSON body.
      #
      # @param value [Hash, Array, Object] parsed JSON: a Hash or Array is walked, any
      #   other value is a leaf
      # @return [Hash{Symbol => Object}, Array, Object] a new structure of the same shape
      #   with Symbol keys; a leaf is returned as it came
      def deep_symbolize(value)
        case value
        when Hash  then value.to_h { |k, v| [k.to_sym, deep_symbolize(v)] }
        when Array then value.map { |item| deep_symbolize(item) }
        else value
        end
      end

      # Unwraps a record, a query row, or any value holding `Runtime::Value`s into plain
      # Hashes, Arrays and scalars a JSON encoder can walk.
      #
      # Delegates to `Runtime::Value.materialize`; the only addition is `#to_h` on a
      # `Handle`, which `materialize` does not recognize.
      #
      # @param value [Doors::Handle, Runtime::Value, Hash, Array, Object] what to unwrap;
      #   a `Handle` is read through its `to_h`, so its `:id` comes along
      # @return [Hash, Array, Object] the same data with every `Runtime::Value` replaced
      #   by a Hash of its fields; any other value is returned as it came
      def materialize(value)
        value = value.to_h if value.is_a?(Handle)
        Runtime::Value.materialize(value)
      end

      # Turns a command's JSON body, raw or already parsed, into the `to:`/`with:`
      # envelope a dispatcher takes. The result splats into `Dispatcher#dispatch`.
      #
      # @param body [String, Hash] raw JSON text, or the Hash it parses to
      # @param receiver [Symbol, nil] `:aggregate`, `:entity`, or `nil` for none
      #   (see `CommandRequest.normalize`)
      # @param legacy_receiver [Symbol, String, Hash{Symbol => Symbol, String}, nil] the flat key,
      #   or pair of keys, a body without `to` may name its receiver under; `nil` accepts none
      # @return [Hash{Symbol => Object}] `{ with: facts }`, plus `to:` unless `receiver` is `nil`
      # @raise [JSON::ParserError] if `body` is a String that is not valid JSON
      # @raise [Runtime::TypeMismatch] if the body is not a JSON object or its routing is malformed
      # @raise [ArgumentError] if `receiver` is not `nil`, `:aggregate` or `:entity`
      def command_request(body, receiver:, legacy_receiver: nil)
        input = body.is_a?(String) ? parse(body) : body
        CommandRequest.normalize(input, receiver: receiver, legacy_receiver: legacy_receiver)
      end

      # Parses a raw request body, leaving keys as Strings. `JSON::ParserError` propagates
      # unwrapped.
      #
      # @param raw_json [String] JSON text, such as a POST body
      # @return [Hash{String => Object}, Array, String, Numeric, Boolean, nil] whatever
      #   the text encodes
      # @raise [JSON::ParserError] if the text is not valid JSON
      def parse(raw_json) = JSON.parse(raw_json)
    end
  end
end

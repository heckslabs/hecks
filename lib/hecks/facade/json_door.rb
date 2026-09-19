require "json"
require_relative "handle"
require_relative "command_request"
require_relative "../naming"
require_relative "../runtime/errors"
require_relative "../runtime/value"

module Hecks
  module Facade
    # **The JSON door** — where Facade meets body-in/body-out callers.
    #
    # `Handle`/`Surface` are Ruby sugar over the dispatcher for a Ruby caller
    # holding real objects — a symbol verb name, a `**kwargs` payload, a
    # `Handle` back in hand. A REST-ish JSON API is a caller holding strings
    # instead: a URL segment naming a collection, a URL segment naming a
    # record or a verb, a parsed request body whose every key arrived as a
    # String because that is all JSON ever gives. Every app that wants to put
    # a JSON API in front of a booted domain has to do that translation —
    # name to door module, string to symbol, nested `Runtime::Value` back to
    # plain data. This is that translation written once, generic, reading the
    # same IR the rest of the facade already reads rather than each app
    # re-deriving "how do I find an aggregate by name" against its own routes.
    #
    # ## No HTTP lives here
    #
    # Same discipline `Router` and `Surface` already
    # hold: this module never sees a request object, never picks a status
    # code, never calls `halt`. Every method here takes plain Ruby values in
    # — a raw JSON String is the one exception, see `.parse` below, every
    # other input is already-parsed data — and returns plain Ruby values
    # out, or raises. Turning a raw request body into that input, and
    # turning a raised exception into an HTTP status, both stay the calling
    # app's job, exactly the way they already are for `Router#dispatch`.
    #
    # ## One refusal class for every miss
    #
    # Every "that doesn't exist" case raises `Runtime::NotFound` — the same
    # class every time, not a new one per caller. `Runtime::NotFound` already
    # sits in `Runtime::DOMAIN_REFUSALS` (runtime/errors.rb) — the family a
    # booted app already has, or trivially can have, one generic `error`
    # handler for, mapping the whole family to a status code without a
    # special case per refusal. A bespoke `JsonDoor::CollectionNotFound` (or
    # three of those, one per flavor of "not found") would just force every
    # app that adopts this door to widen its rescue clause to match it — the
    # opposite of what a shared refusal family is for. So "no such
    # aggregate", "no creating command", "no such command", and "no record
    # with that id" all raise the one class, distinguished only by message.
    module JsonDoor
      module_function

      # Resolves a domain name and an aggregate name, as two URL segments carry them, to
      # that aggregate's door.
      #
      # "Banking", "Customer" -> the `Banking::Customer` door module `.find` /
      # `.create_...!` / etc already answer for — the same module
      # `Facade::Handle`'s own reference accessors reach with
      # `Object.const_get` (see handle.rb's `define_reference_accessors`).
      #
      # Checked against the current boot's IR first, not against Ruby's
      # constant table directly — a name that names nothing in this
      # registry should refuse before ever asking Ruby whether some
      # same-named constant happens to exist (possibly a stale one, left
      # over from an earlier boot in this same process — the exact hazard
      # `AggregateDoor#port`'s own comment describes at length). Only once
      # the IR confirms the aggregate is real does this read the constant
      # the current boot's `Surface.install` actually minted for it.
      #
      # @param dispatcher [Runtime::Dispatcher, Runtime::RemoteDispatcher] the booted
      #   dispatcher whose registry decides whether the aggregate exists
      # @param domain [String, Symbol] the chapter name, such as `"Banking"`
      # @param name [String, Symbol] the aggregate's declared name, such as `"Customer"`
      # @return [Module] the aggregate door installed at `domain::name`
      # @raise [Runtime::NotFound] if the registry holds no such chapter, or the chapter
      #   declares no aggregate of that name
      # @raise [NameError] if the IR has the aggregate but no facade constant is
      #   installed for it, as after a boot with `install_facade: false`
      def aggregate(dispatcher, domain, name)
        ir = dispatcher.registry.bluebook(domain)&.aggregate(name)
        raise Runtime::NotFound, "#{domain} declares no aggregate named #{name.inspect}" unless ir

        Object.const_get("#{domain}::#{ir.hecks_name}")
      end

      # Names the door method that creates a record of this aggregate.
      #
      # The one command a POST to a bare collection URL means — "make one of
      # these". A creating command is one that declares no `references`
      # (`Command#creates?`), and the first one the aggregate declares is the
      # one named here; this just names it the same
      # snake_case-plus-bang a Ruby caller would already ask the door for
      # (`Naming.snake`, the identical call `AggregateDoor` itself makes
      # when it defines that singleton method in the first place — `!`
      # because every command carries it, door and Handle alike).
      #
      # @param klass [Module] an aggregate door, as `aggregate` returns; anything
      #   answering `ir` with a `Bluebook::Aggregate` works
      # @return [String] the method name to `public_send` to the door, such as
      #   `"create_pizza!"`
      # @raise [Runtime::NotFound] if the aggregate declares no creating command
      def creating_command(klass)
        creating = klass.ir.commands.find(&:creates?)
        raise Runtime::NotFound, "#{klass.ir.hecks_name} declares no creating command" unless creating

        "#{Naming.snake(creating.hecks_name)}!"
      end

      # Confirms that a command name arriving as text is one a `Handle` of this aggregate
      # answers, before a caller `public_send`s it.
      #
      # A URL segment or a JSON body's "command" field, checked against what
      # a `Handle` can actually dispatch — not `klass.commands`, which is
      # `AggregateDoor`'s own door-level list and includes the one creating
      # command too (`aggregate_door.rb`'s `commands` singleton method maps
      # every `ir.commands`, full stop). A `Handle` only ever defines
      # singleton methods for the non-creating ones
      # (`Handle#define_verb_methods`, `@ir.commands.reject(&:creates?)`) —
      # the creating command lives on the aggregate class itself, dispatched
      # through `.creating_command` above, not through a `Handle` in hand.
      # Accepting a creating-command name here would let it past this gate
      # clean, only to blow up as a raw `NoMethodError` the moment a caller
      # tries `handle.public_send(name, **args)`, instead of the 404 this
      # method promises. Filtering `reject(&:creates?)` here, the same filter
      # `Handle` itself applies, is what keeps "accepted here" and
      # "dispatchable there" the same set.
      #
      # @param klass [Module] an aggregate door, as `aggregate` returns
      # @param name [String, Symbol] the wanted method name with its bang, such as
      #   `"add_topping!"`
      # @return [String] `name` as a String, unchanged, when a `Handle` answers it
      # @raise [Runtime::NotFound] if no non-creating command has that method name,
      #   including when `name` is the creating command's or lacks the `!`
      def validate_command!(klass, name)
        wanted = name.to_s
        dispatchable = klass.ir.commands.reject(&:creates?).map { |command| "#{Naming.snake(command.hecks_name)}!" }
        return wanted if dispatchable.include?(wanted)

        raise Runtime::NotFound, "#{klass.ir.hecks_name} declares no command named #{wanted.inspect}"
      end

      # Fetches one record by id, refusing a miss instead of answering nil.
      #
      # `klass.find` already answers nil-on-miss — the right shape for a
      # Ruby caller that means to check for itself. A JSON caller asking for
      # one record by id off a URL means to have it, or answer 404 — this is
      # that stricter wrapper, raising the same `Runtime::NotFound` the rest
      # of this door raises rather than handing back nil for the caller to
      # remember to check.
      #
      # @param klass [Module] an aggregate door, as `aggregate` returns
      # @param id [String] the record's identity, as the URL carried it
      # @return [Facade::Handle] the record in hand
      # @raise [Runtime::NotFound] if the repository holds no record with that id
      def find!(klass, id)
        klass.find(id) or raise Runtime::NotFound, "no #{klass.ir.hecks_name} found for id #{id.inspect}"
      end

      # Converts every Hash key to a Symbol, at every depth of a parsed JSON body.
      #
      # JSON only ever hands back String keys. A command's args, and every
      # nested value-object literal inside them, need symbol keys before
      # `Handle`/`Dispatcher` will accept them at all — this is that
      # recursive conversion, blind to how deep a body nests.
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
      # Hashes, Arrays and scalars.
      #
      # The other direction: a `Handle`, or a query row's plain state hash,
      # carrying a `Runtime::Value` at every level a value object sits at —
      # down to plain Ruby a JSON encoder can walk without knowing what a
      # `Runtime::Value` is.
      #
      # `Runtime::Value.materialize` (runtime/value.rb) already does the
      # actual recursion — its `Hash` branch calls itself on every value,
      # its `Value` branch unwraps through `#to_h`, which itself calls
      # `materialize` on every field, so a value object three levels deep
      # unwraps three levels deep for free. This is not a second unwrapper
      # sitting next to it: `materialize` covers `Hash`/`Array`/`Value`
      # already, and a `Handle` is none of those three, so the one thing
      # this adds is `#to_h`'ing a `Handle` first so `materialize`'s own
      # `Hash` case can take it from there.
      #
      # @param value [Facade::Handle, Runtime::Value, Hash, Array, Object] what to unwrap;
      #   a `Handle` is read through its `to_h`, so its `:id` comes along
      # @return [Hash, Array, Object] the same data with every `Runtime::Value` replaced
      #   by a Hash of its fields; a value that is none of the listed types is returned
      #   as it came
      def materialize(value)
        value = value.to_h if value.is_a?(Handle)
        Runtime::Value.materialize(value)
      end

      # Turns a command's JSON body, raw or already parsed, into the `to:`/`with:`
      # envelope a dispatcher takes.
      #
      # Parsed JSON and raw JSON text cross the same receiver/payload boundary
      # as CLI and forms. The result is ready to splat into Dispatcher#dispatch
      # and contains no loose routing fields.
      #
      # @param body [String, Hash] raw JSON text, or the Hash it parses to, with String
      #   or Symbol keys
      # @param receiver [Symbol, nil] the kind of receiver the command takes: `:aggregate`,
      #   `:entity`, or `nil` for none (see `CommandRequest.normalize`)
      # @param legacy_receiver [Symbol, String, Hash{Symbol => Symbol, String}, nil] the
      #   flat key, or pair of keys, a body without `to` may name its receiver under;
      #   `nil` accepts none
      # @return [Hash{Symbol => Object}] `{ with: facts }`, plus `to:` whenever `receiver`
      #   is not `nil`
      # @raise [JSON::ParserError] if `body` is a String that is not valid JSON
      # @raise [Runtime::TypeMismatch] if the body is not a JSON object, or its routing is
      #   missing, malformed, or mixed with loose keys beside an explicit `with:`
      # @raise [ArgumentError] if `receiver` is not `nil`, `:aggregate` or `:entity`
      def command_request(body, receiver:, legacy_receiver: nil)
        input = body.is_a?(String) ? parse(body) : body
        CommandRequest.normalize(input, receiver: receiver, legacy_receiver: legacy_receiver)
      end

      # Parses a raw request body, leaving keys as Strings.
      #
      # The one place a raw JSON string is legitimate input for this door —
      # a POST body, still text at the point a generic, HTTP-blind layer can
      # see it. `JSON::ParserError` already names "this wasn't JSON" exactly
      # right ; wrapping it in a bespoke `JsonDoor`-specific class would
      # only be a second name for the same fact, so it propagates exactly as
      # `JSON.parse` raises it — a calling app catches it the same standard
      # way it would catch any other malformed-input error, no new class to
      # learn.
      #
      # @param raw_json [String] JSON text, such as a POST body
      # @return [Hash{String => Object}, Array, String, Numeric, Boolean, nil] whatever
      #   the text encodes; a JSON object becomes a Hash with String keys
      # @raise [JSON::ParserError] if the text is not valid JSON
      def parse(raw_json) = JSON.parse(raw_json)
    end
  end
end

require "json"
require_relative "handle"
require_relative "command_request"
require_relative "../naming"
require_relative "../runtime/errors"
require_relative "../runtime/value"

module Hecks
  module Facade
    # THE JSON DOOR — WHERE Facade MEETS BODY-IN/BODY-OUT CALLERS.
    #
    # `Handle`/`Surface` are Ruby sugar over the dispatcher for a Ruby caller
    # holding real objects — a symbol verb name, a `**kwargs` payload, a
    # `Handle` back in hand. A REST-ish JSON API is a caller holding STRINGS
    # instead: a URL segment naming a collection, a URL segment naming a
    # record or a verb, a parsed request body whose every key arrived as a
    # String because that is all JSON ever gives. Every app that wants to put
    # a JSON API in front of a booted domain has to do that translation —
    # name to class, string to symbol, nested `Runtime::Value` back to plain
    # data — and one sibling app had already hand-written it once, bespoke,
    # against its own routes, before this existed. This is that translation
    # pulled out, generic, reading the SAME IR the rest of the facade already
    # reads rather than re-deriving "how do I find an aggregate by name".
    #
    # NO HTTP LIVES HERE. Same discipline `Router` and `Surface` already
    # hold: this module never sees a request object, never picks a status
    # code, never calls `halt`. Every method here takes plain Ruby values in
    # — a raw JSON String is the one exception, see `.parse` below, every
    # other input is already-parsed data — and returns plain Ruby values
    # out, or raises. Turning a raw request body into that input, and
    # turning a raised exception into an HTTP status, both stay the calling
    # app's job, exactly the way they already are for `Router#dispatch`.
    #
    # EVERY "THAT DOESN'T EXIST" CASE RAISES `Runtime::NotFound` — THE SAME
    # CLASS EVERY TIME, NOT A NEW ONE PER CALLER. `Runtime::NotFound` already
    # sits in `Runtime::DOMAIN_REFUSALS` (runtime/errors.rb) — the family a
    # booted app already has, or trivially can have, ONE generic `error`
    # handler for, mapping the whole family to a status code without a
    # special case per refusal. A bespoke `JsonDoor::CollectionNotFound` (or
    # three of those, one per flavor of "not found") would just force every
    # app that adopts this door to widen its rescue clause to match it — the
    # opposite of what a shared refusal family is for. So "no such
    # aggregate", "no creating command", "no such command", and "no record
    # with that id" all raise the one class, distinguished only by message.
    module JsonDoor
      module_function

      # "Banking", "Customer" -> the `Banking::Customer` class `.find` /
      # `.create_...` / etc already answer for — the same class
      # `Facade::Handle`'s own reference accessors reach with
      # `Object.const_get` (see handle.rb's `define_reference_accessors`).
      #
      # Checked against the CURRENT boot's IR first, not against Ruby's
      # constant table directly — a name that names nothing in this
      # registry should refuse before ever asking Ruby whether some
      # same-named constant happens to exist (possibly a stale one, left
      # over from an earlier boot in this same process — the exact hazard
      # `AggregateDoor#port`'s own comment describes at length). Only once
      # the IR confirms the aggregate is real does this read the constant
      # the current boot's `Surface.install` actually minted for it.
      def aggregate(dispatcher, domain, name)
        ir = dispatcher.registry.bluebook(domain)&.aggregate(name)
        raise Runtime::NotFound, "#{domain} declares no aggregate named #{name.inspect}" unless ir

        Object.const_get("#{domain}::#{ir.hecks_name}")
      end

      # The one command a POST to a bare collection URL means — "make one of
      # these". `AggregateDoor` already enforces exactly one creating
      # command per aggregate (`Command#creates?`, true exactly when the
      # command declares no `references`); this just names it the same
      # snake_case-plus-bang a Ruby caller would already ask the door for
      # (`Naming.snake`, the identical call `AggregateDoor` itself makes
      # when it defines that singleton method in the first place — `!`
      # because every command does now, door and Handle alike).
      def creating_command(klass)
        creating = klass.ir.commands.find(&:creates?)
        raise Runtime::NotFound, "#{klass.ir.hecks_name} declares no creating command" unless creating

        "#{Naming.snake(creating.hecks_name)}!"
      end

      # A URL segment or a JSON body's "command" field, checked against what
      # the aggregate actually declares. `klass.commands` is the same
      # sorted, snake_cased list `AggregateDoor` built for its own door, so
      # a name this accepts is a name a `Handle` can actually dispatch.
      def validate_command!(klass, name)
        wanted = name.to_s
        return wanted if klass.commands.include?(wanted)

        raise Runtime::NotFound, "#{klass.ir.hecks_name} declares no command named #{wanted.inspect}"
      end

      # `klass.find` already answers nil-on-miss — the right shape for a
      # Ruby caller that means to check for itself. A JSON caller asking for
      # one record by id off a URL means to HAVE it, or answer 404 — this is
      # that stricter wrapper, raising the same `Runtime::NotFound` the rest
      # of this door raises rather than handing back nil for the caller to
      # remember to check.
      def find!(klass, id)
        klass.find(id) or raise Runtime::NotFound, "no #{klass.ir.hecks_name} found for id #{id.inspect}"
      end

      # JSON only ever hands back String keys. A command's args, and every
      # nested value-object literal inside them, need symbol keys before
      # `Handle`/`Dispatcher` will accept them at all — this is that
      # recursive conversion, blind to how deep a body nests.
      def deep_symbolize(value)
        case value
        when Hash  then value.to_h { |k, v| [k.to_sym, deep_symbolize(v)] }
        when Array then value.map { |item| deep_symbolize(item) }
        else value
        end
      end

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
      def materialize(value)
        value = value.to_h if value.is_a?(Handle)
        Runtime::Value.materialize(value)
      end

      # Parsed JSON and raw JSON text cross the same receiver/payload boundary
      # as CLI and forms. The result is ready to splat into Dispatcher#dispatch
      # and contains no loose routing fields.
      def command_request(body, receiver:, legacy_receiver: nil)
        input = body.is_a?(String) ? parse(body) : body
        CommandRequest.normalize(input, receiver: receiver, legacy_receiver: legacy_receiver)
      end

      # The one place a raw JSON string is legitimate input for this door —
      # a POST body, still text at the point a generic, HTTP-blind layer can
      # see it. `JSON::ParserError` already names "this wasn't JSON" exactly
      # right ; wrapping it in a bespoke `JsonDoor`-specific class would
      # only be a second name for the same fact, so it propagates exactly as
      # `JSON.parse` raises it — a calling app catches it the same standard
      # way it would catch any other malformed-input error, no new class to
      # learn.
      def parse(raw_json) = JSON.parse(raw_json)
    end
  end
end

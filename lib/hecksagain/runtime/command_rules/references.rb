require_relative "../errors"
require_relative "../refusal_wording"

module Hecksagain
  module Runtime
    class CommandRules
      # A reference must point at something that EXISTS.
      #
      # `reference_to Customer` is the one guarantee an aggregate reference is
      # for, and it was declared 14 times across banking and enforced nowhere :
      # an Account could belong to a customer who was never registered, and
      # every gate stayed green because
      # no corpus step ever passed a dangling reference.
      module References
        # Resolved here rather than in coercion because coercion is pure — it
        # holds no repository. A reference INTO ANOTHER DOMAIN is left alone : a
        # cross-domain target may legitimately not be loaded, which is the same
        # reading `across` policies already get.
        #
        # Shared by CommandInterpreter and EntityInterpreter — an entity command
        # can declare a reference-typed attribute the same way an aggregate
        # command can, even though nothing in the real corpus does yet.
        def resolve_references(domain, command, args)
          command.attributes.each do |attribute|
            next unless attribute.reference?
            next unless args.key?(attribute.name)

            held = args[attribute.name]
            next if held.nil?

            target = referenced_aggregate(attribute)
            next unless target

            # The id itself — a reference that arrived as anything else was
            # already refused at the payload gate.
            key = held.to_s
            next if key.to_s.empty?
            next if @registry.repository(domain, target).find(key)

            # THE HEADS NAME WHAT A CALLER PASSES, so they are what a refusal
            # names — every one of them. This read `identified_by`, which is the
            # SINGLE head and is nil the moment an identity has two parts, so a
            # composite target was reported as known by `id` — a field it does
            # not have, and the one word this runtime is careful never to invent.
            # Single-path targets read exactly as before, which is every member
            # of the corpus but Market.
            raise NotFound,
                  RefusalWording.render("NotFound", "reference_target_missing",
                                        target: target.name, heads: target.identity_heads.join(", "),
                                        key: key.inspect)
          end
        end

        # The reference RESOLVES itself — through the chapter's own IR, so the
        # bluebook's declared heads are the index. This used to regex the target's
        # name out of "Reference<Customer>" and then search
        # `registry.bluebook(domain).aggregates` for it — and later reached the
        # target through Ruby's constant tree, a class thrown away for its `.ir`
        # the moment it was found.
        def referenced_aggregate(attribute)
          attribute.type.resolve
        end

        # A related record's OWN fields, reachable by name from `given`/
        # `ensures` — `customer.status`, `account.customer.status` — without
        # teaching the pure expression evaluator anything about
        # repositories. The lookup happens HERE, once, before evaluation;
        # `Resolver#lookup` just digs into a plain Hash exactly as it
        # always has.
        #
        # `owner` is either the declaring aggregate/entity (its OWN
        # `reference_to`, read off `source` — the record's stored state)
        # or the command itself (a reference-typed ARGUMENT, read off
        # `source` — the dispatch payload). Same shape either way: every
        # reference-typed attribute `owner` declares becomes a key in the
        # result, named by stripping the attribute's own `_id` suffix
        # (`customer_id` → `customer`) — a no-op for an aliased reference
        # that already carries no suffix (`reference_to Account, as:
        # :source` → `source`), which is why this needs no separate case
        # for `as:`.
        #
        # RECURSES into what it finds, so a chain like
        # `account.customer.status` resolves in one pass: hydrating
        # `account` also hydrates ITS OWN `customer_id` into a nested
        # `customer` key. Depth-bounded rather than cycle-detected — nothing
        # in this corpus dots more than two hops, and a bound is simpler
        # than tracking visited (type, id) pairs for a cycle nothing here
        # declares.
        DEREFERENCE_DEPTH = 4
        private_constant :DEREFERENCE_DEPTH

        def dereference(domain, owner, source, depth: DEREFERENCE_DEPTH)
          return {} if depth <= 0 || owner.nil?

          owner.attributes.each_with_object({}) do |attribute, hydrated|
            next unless attribute.reference?

            id = source[attribute.name]
            next if id.nil?

            target = referenced_aggregate(attribute)
            next unless target

            record = @registry.repository(domain, target).find(id.to_s)
            next unless record

            name = attribute.name.to_s.sub(/_id\z/, "").to_sym
            hydrated[name] = record.state.merge(dereference(domain, target, record.state, depth: depth - 1))
          end
        end
      end
    end
  end
end

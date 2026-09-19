require_relative "../../storage_shape"

module Hecks
  module Translation
    module Scaffold
      # Diff two eras' storage-shape projections into the edge's
      # declarations — confident rules by unique signature pairing,
      # everything ambiguous left unresolved for a human.
      module Differ
        # Diff two bluebook IRs into the edge's declarations.
        #
        # @param held_bluebook [Bluebook::Chapter] the bluebook IR for the held (source) era
        # @param current_bluebook [Bluebook::Chapter] the bluebook IR for the current
        #   (destination) era
        # @return [Hash{Symbol => Object}] `:aggregates` (Array of `ScaffoldedAggregate`,
        #   only aggregates with a rename or a rule), `:retired` (Array of vanished aggregate
        #   names with no successor) and `:unclaimed` (Array of vanished aggregate names left
        #   ambiguous)
        def diff(held_bluebook, current_bluebook)
          held_shapes = projections(held_bluebook)
          current_shapes = projections(current_bluebook)

          matched = match_aggregates(held_shapes, current_shapes)
          aggregates = current_bluebook.aggregates.filter_map do |aggregate|
            held_name = matched[:pairs][aggregate.name]
            next unless held_name

            rules = attribute_rules(held_shapes[held_name], current_shapes[aggregate.name])
            was = held_name == aggregate.name ? nil : held_name
            next if rules.empty? && was.nil?

            ScaffoldedAggregate.new(name: aggregate.name, was: was, rules: rules)
          end

          { aggregates: aggregates, retired: matched[:retired], unclaimed: matched[:unclaimed] }
        end

        # Projects a bluebook's storage shape and indexes it by aggregate name.
        #
        # @param bluebook [Bluebook::Chapter] the bluebook IR to project
        # @return [Hash{String => Hash}] `Runtime::StorageShape.project(bluebook)`'s
        #   aggregate Hashes, keyed by their own `"name"`
        def projections(bluebook)
          Runtime::StorageShape.project(bluebook)["aggregates"].to_h { |shape| [shape["name"], shape] }
        end

        # Pairs each current aggregate with its held-era counterpart by name or by exact
        # shape match, and sorts every unmatched held aggregate into retired or unclaimed.
        #
        # A vanished aggregate whose full shape reappears under exactly one
        # new name is treated as a rename. `retired` is only confident when nothing
        # remains it could plausibly have become — a vanished aggregate
        # beside an unmatched new one might be a rename-plus-reshape, and
        # writing `retired` there would be a guess that strands data.
        # Anything ambiguous stays unclaimed, and the coverage gate names
        # it until a human decides.
        #
        # @param held_shapes [Hash{String => Hash}] held-era aggregate shapes, from
        #   `projections`
        # @param current_shapes [Hash{String => Hash}] current-era aggregate shapes, from
        #   `projections`
        # @return [Hash{Symbol => Object}] `:pairs` (Hash of current name to held name or
        #   nil); the vanished held names with no confident rename go to `:retired` when no
        #   current aggregate appeared unmatched at all, otherwise to `:unclaimed`, the other
        #   key always `[]`
        def match_aggregates(held_shapes, current_shapes)
          pairs = {}
          current_shapes.each_key { |name| pairs[name] = held_shapes.key?(name) ? name : nil }

          vanished = held_shapes.keys - current_shapes.keys
          appeared = current_shapes.keys.select { |name| pairs[name].nil? }
          unclaimed = []
          vanished.each do |old_name|
            old_shape = held_shapes[old_name].merge("name" => nil)
            candidates = appeared.select { |name| current_shapes[name].merge("name" => nil) == old_shape }
            if candidates.size == 1
              pairs[candidates.first] = old_name
              appeared -= candidates
            else
              unclaimed << old_name
            end
          end

          retired = appeared.empty? ? unclaimed : []
          { pairs: pairs, retired: retired, unclaimed: retired.empty? ? unclaimed : [] }
        end

        # Every changed path in one aggregate, resolved into rules by
        # signature matching over the full path set — top-level names and
        # dotted members alike. Unique signature pair: a rename (both
        # top-level) or a move (any dotted end). Same path, same members,
        # new type name: a retype. Anything else: unresolved, carrying its
        # type-compatible candidates (an empty list is the arrow toward
        # compute, or drop).
        #
        # @param held_shape [Hash] the held-era aggregate's projected shape
        # @param current_shape [Hash] the current-era aggregate's projected shape
        # @return [Array<Hash{Symbol => Object}>] rule Hashes with `:kind` (`:rename`,
        #   `:move`, `:retype` or `:unresolved`) plus `:from`/`:to`, or `:from`/`:candidates`
        #   for `:unresolved`
        def attribute_rules(held_shape, current_shape)
          rules = []
          rules << identity_hint(held_shape, current_shape)
          rules.compact!
          held_attrs = (held_shape["attributes"] || []).to_h { |attribute| [attribute["name"], attribute] }
          current_attrs = (current_shape["attributes"] || []).to_h { |attribute| [attribute["name"], attribute] }

          rules.concat(retype_rules(held_attrs, current_attrs))
          retyped = rules.filter_map { |rule| rule[:from] if rule[:kind] == :retype }

          vanished = vanished_paths(held_attrs, current_attrs, retyped)
          appeared = appeared_paths(held_attrs, current_attrs, retyped)

          # Mutates `rules` in place (not build-and-concat, like the two
          # passes above) because it must read its own earlier writes:
          # `taken`, below, is recomputed from `rules` at the top of every
          # iteration, so a target this same loop already claimed for an
          # earlier vanished path is excluded from a later one. Passing a
          # snapshot instead of the live array would let two vanished
          # paths both match the same appeared target.
          resolve_vanished_rules!(rules, vanished, appeared)
          rules
        end

        # Finds attributes whose type's own name changed with its member structure unchanged.
        #
        # retype pass: same attribute name, same member structure, the
        # type's own name changed
        #
        # @param held_attrs [Hash{String => Hash}] held-era attribute shapes by name
        # @param current_attrs [Hash{String => Hash}] current-era attribute shapes by name
        # @return [Array<Hash{Symbol => String}>] `{kind: :retype, from:, to:}` Hashes, one
        #   per attribute name present in both with the same container shape but a different
        #   type name
        def retype_rules(held_attrs, current_attrs)
          (held_attrs.keys & current_attrs.keys).filter_map do |name|
            held = held_attrs[name]
            current = current_attrs[name]
            next if held == current
            next unless container?(held) && container?(current)
            next unless held["type"]["members"] == current["type"]["members"] && held["list"] == current["list"]

            { kind: :retype, from: held["type"]["type"], to: current["type"]["type"] }
          end
        end

        # Matches each vanished path against the appeared paths with the same signature,
        # appending a rename, move or unresolved rule to `rules` for each.
        #
        # @param rules [Array<Hash>] the rules accumulated so far; appended to in place
        # @param vanished [Hash{String => Object}] held paths absent (or retyped away) from
        #   `current_attrs`, mapped to their type signature
        # @param appeared [Hash{String => Object}] current paths with no held counterpart,
        #   mapped to their type signature
        # @return [void]
        def resolve_vanished_rules!(rules, vanished, appeared)
          vanished.each do |path, signature|
            matches = appeared.select { |_, candidate| candidate == signature }.keys
            taken = rules.filter_map { |rule| rule[:to] if %i[rename move].include?(rule[:kind]) }
            matches -= taken
            if matches.size == 1 && vanished.one? { |_, other| other == signature }
              target = matches.first
              kind = path.include?(".") || target.include?(".") ? :move : :rename
              rules << { kind: kind, from: path, to: target }
            else
              candidates = matches.empty? ? compatible_candidates(appeared, signature) : matches
              rules << { kind: :unresolved, from: path, candidates: candidates }
            end
          end
        end

        # Held paths that need explaining: whole attributes that vanished,
        # and members that vanished (or changed type) inside a kept
        # attribute — mirroring exactly what EraGuard will demand coverage
        # for.
        #
        # @param held_attrs [Hash{String => Hash}] held-era attribute shapes by name
        # @param current_attrs [Hash{String => Hash}] current-era attribute shapes by name
        # @param retyped [Array<String>] type names `retype_rules` already accounted for
        # @return [Hash{String => Object}] bare or dotted paths mapped to their held type
        #   signature
        def vanished_paths(held_attrs, current_attrs, retyped)
          paths = {}
          held_attrs.each do |name, held|
            next if retyped.include?(container?(held) ? held["type"]["type"] : nil)

            current = current_attrs[name]
            if current.nil?
              paths[name] = held["type"]
              next
            end
            next if held == current

            held_members = members_of(held)
            current_members = members_of(current)
            held_members.each do |member, signature|
              paths["#{name}.#{member}"] = signature if current_members[member] != signature
            end
          end
          paths
        end

        # The mirror of `vanished_paths`: current paths a held shape does not account for.
        #
        # @param held_attrs [Hash{String => Hash}] held-era attribute shapes by name
        # @param current_attrs [Hash{String => Hash}] current-era attribute shapes by name
        # @param retyped [Array<String>] type names `retype_rules` already accounted for
        # @return [Hash{String => Object}] bare or dotted paths mapped to their current type
        #   signature
        def appeared_paths(held_attrs, current_attrs, retyped)
          paths = {}
          current_attrs.each do |name, current|
            next if retyped.include?(container?(current) ? current["type"]["type"] : nil)

            held = held_attrs[name]
            if held.nil?
              paths[name] = current["type"]
              next
            end
            next if held == current

            held_members = members_of(held)
            members_of(current).each do |member, signature|
              paths["#{name}.#{member}"] = signature if held_members[member] != signature
            end
          end
          paths
        end

        # The one thing `attribute_rules` could not see before — the shape
        # projection already carries `"identity"` (`StorageShape
        # .project_aggregate`), it was simply never read here. An
        # unresolved placeholder, not a guess: `coverage_check.rb`'s own
        # `check_identity_unchanged!` is the real gate this only hints
        # toward, the same "tool proactively guides you" pattern the
        # generic unresolved message already gives unfed fields.
        #
        # @param held_shape [Hash] the held-era aggregate's projected shape
        # @param current_shape [Hash] the current-era aggregate's projected shape
        # @return [Hash{Symbol => Object}, nil] an `:unresolved` rule Hash when the declared
        #   identity path changed; nil when it did not
        def identity_hint(held_shape, current_shape)
          return if held_shape["identity"] == current_shape["identity"]

          { kind: :unresolved, from: :identity, candidates: [] }
        end

        # Widens an unmatched-signature vanished path's candidates to appeared paths that at
        # least share its scalar/member shape, for the human to choose among.
        #
        # @param appeared [Hash{String => Object}] current paths with no held counterpart,
        #   mapped to their type signature
        # @param signature [Object] the vanished path's own type signature
        # @return [Array<String>] appeared paths whose `scalar_of` matches `signature`'s
        def compatible_candidates(appeared, signature)
          appeared.select { |_, candidate| scalar_of(candidate) == scalar_of(signature) }.keys
        end

        # Reduces a type signature to its member structure, ignoring the container type's
        # own name — what two differently-named but structurally identical types share.
        #
        # @param signature [Hash, Object] a type signature, as `projections` shapes it
        # @return [Array, Object] the container's `"members"` Array when `signature` is a
        #   Hash (a value object or entity type); `signature` itself for a scalar
        def scalar_of(signature) = signature.is_a?(Hash) ? signature["members"] : signature

        # Maps a value-object or entity attribute's own member names to their type signatures.
        #
        # @param attribute [Hash] an attribute shape, as `projections` shapes it
        # @return [Hash{String => Object}] member name to type signature; `{}` for a scalar
        #   attribute
        def members_of(attribute)
          return {} unless container?(attribute)

          attribute["type"]["members"].to_h { |member| [member["name"], member["type"]] }
        end

        # Reports whether an attribute's type is a value object or entity, not a scalar.
        #
        # @param attribute [Hash] an attribute shape, as `projections` shapes it
        # @return [Boolean] true when the attribute's `"type"` is itself a Hash
        def container?(attribute) = attribute["type"].is_a?(Hash)
      end
    end
  end
end

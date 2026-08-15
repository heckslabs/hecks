
require "spec_helper"

# A GRAPH ASSEMBLED FROM DECLARATIONS IS THE GRAPH THE BUILDER MAKES.
#
# `Assembly` takes the hash `to_h` spells and returns the object graph the runtime
# runs. That makes it the exact inverse of `to_h`, and this holds it to that for
# every chapter in the tree:
#
#     Assembly.call(built.to_h).to_h == built.to_h
#
# It is tested against the BUILDER's hash rather than the meta-domain's on purpose.
# The two are already proven byte-identical and unsorted by spec/round_trip_spec, so
# feeding the builder's keeps this spec about one thing — whether declarations
# rebuild into objects faithfully — instead of two.
#
# Every chapter, not the four the round trip walks: a shape only one bluebook
# exercises is exactly the shape a partial corpus lets through.
RSpec.describe "a graph assembled from declarations" do
  # Reachable both from the example group, to generate the examples, and from
  # inside one.
  ASSEMBLY_CORPUS = {
    "Pizzas"     => "examples/pizzas/bluebook/pizzas.bluebook",
    "Banking"    => "examples/banking/bluebook/banking.bluebook",
    "Expression" => "lib/hecksagain/grammar/expression.bluebook",
    "TillRoom"   => "spec/fixtures/till.bluebook",
    "Wire"       => "spec/fixtures/settlement.bluebook",
    "Reflex"     => "spec/fixtures/reflex.bluebook"
  }.freeze

  def load_chapter(file)
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(InMemoryDomain::ROOT, file))
    end
    registry
  end

  # Names the field that moved rather than dumping two documents.
  def differences(source, back, path = "")
    return [] if source == back

    if source.is_a?(Hash) && back.is_a?(Hash)
      (source.keys | back.keys).flat_map { |key| differences(source[key], back[key], "#{path}.#{key}") }
    elsif source.is_a?(Array) && back.is_a?(Array) && source.size == back.size
      source.each_with_index.flat_map { |held, i| differences(held, back[i], "#{path}[#{i}]") }
    else
      ["#{path}: declared #{source.inspect[0, 70]}, assembled #{back.inspect[0, 70]}"]
    end
  end

  def assert_inverse(built)
    assembled = Hecksagain::Bluebook::Assembly.call(built.to_h)

    expect(differences(built.to_h, assembled.to_h)).to be_empty
  end

  ASSEMBLY_CORPUS.each do |name, file|
    it "rebuilds #{name} exactly as it was declared" do
      assert_inverse(load_chapter(file).bluebook(name))
    end
  end

  %w[Bluebook World].each do |name|
    it "rebuilds #{name}, the language itself, exactly as it was declared" do
      assert_inverse(Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook(name))
    end
  end

  describe "the table, held to the language" do
    def plan
      Hecksagain::Bluebook::MetaValidator::Plan.for(
        Hecksagain::Bluebook::MetaValidator.grammar_registry
      )
    end

    # EVERY FIELD THE LANGUAGE DECLARES IS EITHER ASSEMBLED OR NAMED AS DERIVED.
    #
    # This is the judge-coverage lesson, in the other direction. The judge used to
    # carry a hand-written branch per category, and the price was fourteen verbs the
    # language declared and the walk never offered — every rule hanging off them
    # decoration, and nothing red, because a branch that does not exist cannot fail.
    # An assembler with a method per category is the same shape, so the table is
    # checked against the language rather than hand-kept: add a field to
    # bluebook.bluebook and forget to assemble it, and this says so.
    # Read off the aggregate's OWN ATTRIBUTES, not only the creating command's
    # arguments. `Plan#fields` is the latter, and the first draft of this example
    # used it — so adding `attribute :nickname` to the language's Bluebook passed
    # unnoticed, because nothing had taught `Declare` to carry it yet. What an
    # assembly must account for is what the language STORES.
    def stored_fields(meta, category)
      aggregate = meta.aggregate(category)
      declared  = plan.category(category)

      (aggregate.attributes.map(&:name) +
       declared.fields.map(&:to_sym) +
       declared.appends.keys.map(&:to_sym) +
       declared.setters.flat_map { |setter| setter.targets.keys.map(&:to_sym) })
        .uniq
        # A PARENT POINTER is derived by structure, not by a contract. The
        # bare field `declared.parent_key` names is the reference to
        # whatever declares the construct — an aggregate's chapter, a
        # verb's head, a piece's head, a member's shape — and the
        # containment tree already knows it, which is precisely how the
        # assembly walks. An explicit `as:` still keeps its `_id` (Command's
        # own `entity_id`, kept as data — never the parent link itself,
        # which mints bare now, ADR 0025) and is excluded the same way.
        # Requiring thirteen contracts to each restate one would be a list
        # nobody reads, and the day one went stale it would say nothing.
        .reject { |field| field.to_s.end_with?("_id") || field == declared.parent_key&.to_sym }
    end

    it "consumes or explicitly derives every field the language declares" do
      meta = Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

      unclaimed = plan.names.flat_map do |category|
        contract = Hecksagain::Bluebook::Assembly.contract(category)

        stored_fields(meta, category)
          .reject { |field| contract.declares?(field) }
          .map { |field| "#{category}##{field}" }
      end

      expect(unclaimed).to be_empty,
                           "the language declares #{unclaimed.size} field(s) no contract accounts for, " \
                           "so a graph assembled from them would drop each one in silence:\n  " \
                           "#{unclaimed.join("\n  ")}"
    end

    it "names a contract for every category the language declares" do
      missing = plan.names.reject do |category|
        Hecksagain::Bluebook::Assembly::CONTRACTS.key?(category)
      end

      expect(missing).to be_empty,
                         "the language declares #{missing.join(', ')} and the table has no contract for it"
    end

    # EVERY `derived:` CLAIM IS CHECKED, and this is the hole it closes.
    #
    # `derived:` used to be a list of names, which the coverage example above
    # accepted without asking anything. So writing `derived: %i[version]` would have
    # passed while dropping a chapter's version in silence — measured, not
    # supposed: declaring a field in the language and calling it derived left the
    # whole suite green, and only `spec/golden/ir` moved, which is regenerated on
    # purpose and would have buried it.
    #
    # A claim now has a KIND, and every kind can fail.
    it "justifies every derived field with a claim that can be false" do
      keys = declaration_keys

      unjustified = plan.names.flat_map do |category|
        contract = Hecksagain::Bluebook::Assembly.contract(category)

        contract.derived.filter_map do |field, kind|
          fault = fault_in(category, contract, field, kind, keys)
          "#{category}##{field} claims #{kind.inspect} — #{fault}" if fault
        end
      end

      expect(unjustified).to be_empty,
                             "#{unjustified.size} derived claim(s) do not hold:\n  #{unjustified.join("\n  ")}"
    end

    def fault_in(category, contract, field, kind, keys)
      case kind
      when :parent
        return nil if field.to_s.end_with?("_id")
        return nil if Hecksagain::Bluebook::Assembly::PARENT_POINTERS.include?(field)

        "no parent names it — a pointer is a *_id or one of #{Hecksagain::Bluebook::Assembly::PARENT_POINTERS.inspect}"
      when :children
        child = Hecksagain::Naming.pascal(field.to_s.sub(/s\z/, ""))
        return nil if plan.category(child)&.parent == category

        "no category #{child} is declared with #{category} as its parent"
      when :elsewhere
        return nil if Hecksagain::Bluebook::Assembly.elsewhere?(category, field)

        "elsewhere is allow-listed one at a time, and this is not on the list"
      when :walk
        # SUPPLIED BY THE WALK, SPENT ON THE ORDERING. A node does not know where it
        # sits among its siblings, so the walk supplies it and no construct carries
        # it. The claim is false in the one way that matters : if the ask does not
        # order by the field then nothing consumes it at all, and calling it derived
        # would drop a declared field in exactly the silence this gate exists to break.
        return nil if ordered_by?(category, field)

        "#{category}.DeclaredIn does not order by it, so nothing consumes it"
      when Array
        fault_in_pair(contract, field, kind, keys)
      else "no such kind"
      end
    end

    def fault_in_pair(contract, _field, kind, keys)
      shape, target = kind

      case shape
      when :computed
        return nil if contract.computes?(target)
        return "#{contract.holder} takes #{target} as a keyword, so it is STORED, not computed" if contract.accepts?(target)

        "#{contract.holder} does not answer to #{target}"
      when :folded
        # The object(s) it folds into AND the member it is, so a mistyped member is
        # caught too — `[:folded, :order_by, :directionn]` names a key nothing carries.
        wanted = Array(target) + [kind[2]].compact
        absent = wanted.reject { |key| keys.include?(key) }
        absent.empty? ? nil : "nothing folds into #{absent.inspect} — no declaration carries those keys"
      else "no such kind"
      end
    end

    # Whether the category's own way back orders by the field — the proof that a
    # walk-supplied field is consumed rather than merely stored.
    def ordered_by?(category, field)
      meta = Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
      ask  = meta.aggregate(category)&.query("DeclaredIn")

      ask&.order_by&.field.to_s == field.to_s
    end

    # Every key a REAL reconstructed declaration carries, gathered once. A fold has
    # to land somewhere, and this is what says whether it does.
    def declaration_keys
      @declaration_keys ||= ASSEMBLY_CORPUS.values.flat_map { |file|
        built = load_chapter(file).bluebook(File.basename(file, ".bluebook").capitalize) ||
                load_chapter(file).bluebooks.values.first
        keys_in(Hecksagain::Bluebook::MetaValidator.hold(built)[:declaration])
      }.uniq
    end

    def keys_in(node)
      case node
      when Hash  then node.keys + node.values.flat_map { |held| keys_in(held) }
      when Array then node.flat_map { |held| keys_in(held) }
      else []
      end
    end

    # THE WRITE DIRECTION IS HELD TO THE LANGUAGE TOO.
    #
    # `Readings#rows_for` was nine cases keyed "Category.list" and now reads the
    # table, so the same question can be asked of it: does every list the language
    # declares have a way to be offered, and does every shaper the table names exist?
    it "offers every appendable list, by a shaper that exists or a reader on the holder" do
      unreadable = plan.names.flat_map do |category|
        contract = Hecksagain::Bluebook::Assembly.contract(category)

        plan.category(category).appends.keys.filter_map do |list|
          shaper = contract.shaper(list)
          next "#{category}##{list} names shaper #{shaper} and Readings has no such method" if shaper && !readings.include?(shaper)
          next nil if shaper
          next nil if contract.holder.nil? || contract.answers?(list.to_sym)

          "#{category}##{list} has no shaper and #{contract.holder} does not answer to it"
        end
      end

      expect(unreadable).to be_empty,
                            "#{unreadable.size} list(s) the language declares cannot be offered:\n  " \
                            "#{unreadable.join("\n  ")}"
    end

    def readings = Hecksagain::Bluebook::MetaValidator::Readings.instance_methods(false)

    # THE READ DIRECTION, HELD THE SAME WAY.
    #
    # `Reconstruction` had eleven methods, one per category, each spelling out keys
    # the table already names. Six read the table now, and the exceptions live in its
    # `reads:` column — so the same two questions apply: does every read exception
    # name a key that exists, and does every reader it names exist?
    it "reads every declaration key by a reader that exists, for a key the table names" do
      meta    = Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
      readers = Hecksagain::Bluebook::MetaValidator::Reconstruction.private_instance_methods(false) +
                Hecksagain::Bluebook::MetaValidator::Shapes.instance_methods(false)

      broken = plan.names.flat_map do |category|
        contract = Hecksagain::Bluebook::Assembly.contract(category)
        named    = contract.fields.values.map(&:first)

        Hash(contract.reads).filter_map do |key, spec|
          next "#{category}##{key} is read but no field declares it" unless named.include?(key)

          # `[:from, row_key]` names a ROW KEY, not a reader — the declaration key and
          # the language's field are spelled differently for exactly one thing, a
          # dispatch's bindings. So what it names must be a field of that category.
          if spec.is_a?(Array) && spec.first == :from
            next nil if stored_fields(meta, category).include?(spec.last)

            next "#{category}##{key} reads from #{spec.last}, which the language does not declare"
          end

          method = spec.is_a?(Array) ? spec.last : spec
          next nil unless method.is_a?(Symbol) && !%i[symbol names].include?(method)
          next nil if readers.include?(method)

          "#{category}##{key} names reader #{method}, which does not exist"
        end
      end

      expect(broken).to be_empty,
                        "#{broken.size} read exception(s) do not hold:\n  #{broken.join("\n  ")}"
    end

    # WHY THE CONTAINMENT IS NOT ON THE TABLE, measured rather than assumed.
    #
    # Folding `aggregate`, `entity` and the chapter would mean the table listing each
    # one's children — except the plan already knows every parent-child edge, so the
    # honest version would DERIVE them. It does not work, and this is why: a
    # category's parent comes from the one `*_id` its creating command carries, and
    # `Command.Declare` carries `aggregate_id` before `entity_id`. So the plan says an
    # ENTITY HAS NO CHILDREN, and a piece's own verbs and asks — the `own` / `within`
    # partition — is exactly the case a derived walk would have to except.
    #
    # Five categories out of six for free and a hand-written exception for the one
    # that matters is not a fold, it is a fold plus the thing the fold was for.
    it "cannot derive an entity's children from the plan, which is why containment is code" do
      expect(plan.names.select { |name| plan.category(name).parent == "Entity" }).to be_empty
      expect(plan.category("Command").parent).to eq("Aggregate")
      expect(plan.category("Query").parent).to eq("Aggregate")
    end

    it "claims nothing the language does not declare" do
      # The other half of the same failure: a contract for a retired category, or a
      # field renamed in the language and left behind here, would be dead weight
      # nothing exercises.
      declared = plan.names
      phantom  = Hecksagain::Bluebook::Assembly::CONTRACTS.keys - declared

      expect(phantom).to be_empty
    end
  end

  it "gives the assembled head a working graph, not just a bag of fields" do
    # The graph is what the runtime RUNS, so an assembled aggregate has to carry
    # the same verbs, fields and owned shapes the DSL would have built.
    built     = load_chapter(ASSEMBLY_CORPUS.fetch("Pizzas")).bluebook("Pizzas")
    assembled = Hecksagain::Bluebook::Assembly.call(built.to_h)
    pizza     = assembled.aggregate("Order")

    expect(pizza.command("CreatePizza").creates?).to be(true)
    expect(pizza.command("AddTopping").acts_on).to be(pizza)
    expect(pizza.attributes.map(&:name)).to include(:name, :toppings)
    expect(pizza.value_object("Price").hecks_fqn).to eq("Pizzas::Order.Price")
  end

  it "gives an assembled reference a resolvable edge" do
    built     = load_chapter(ASSEMBLY_CORPUS.fetch("Banking")).bluebook("Banking")
    assembled = Hecksagain::Bluebook::Assembly.call(built.to_h)
    account   = assembled.aggregate("Account")

    expect(account.attribute(:customer).type.resolve)
      .to be(assembled.aggregate("Customer"))
  end
end

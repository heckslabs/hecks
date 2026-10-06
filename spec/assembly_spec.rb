require "spec_helper"

# A graph assembled from declarations is the graph the builder makes.
#
# `Assembly` is the inverse of `to_h`: `Assembly.call(built.to_h).to_h == built.to_h`,
# checked for every chapter in the corpus against the builder's hash.
RSpec.describe "a graph assembled from declarations" do
  # A constant so it is reachable both when generating examples and inside them.
  ASSEMBLY_CORPUS = {
    "Pizzas"     => "examples/pizzas/bluebook/pizzas.bluebook",
    "Banking"    => InMemoryDomain::BANKING_BLUEBOOK_DIR,
    "Expression" => "lib/hecks/grammar/expression.bluebook",
    "TillRoom"   => "spec/fixtures/till.bluebook",
    "Wire"       => "spec/fixtures/settlement.bluebook",
    "Reflex"     => "spec/fixtures/reflex.bluebook"
  }.freeze

  def load_chapter(file)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      path = File.absolute_path(file, InMemoryDomain::ROOT)
      load_bluebook_files(path)
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
    assembled = Hecks::Bluebook::Assembly.call(built.to_h)

    expect(differences(built.to_h, assembled.to_h)).to be_empty
  end

  ASSEMBLY_CORPUS.each do |name, file|
    it "rebuilds #{name} exactly as it was declared" do
      assert_inverse(load_chapter(file).bluebook(name))
    end
  end

  %w[Bluebook World].each do |name|
    it "rebuilds #{name}, the language itself, exactly as it was declared" do
      assert_inverse(Hecks::Bluebook::MetaValidator.grammar_registry.bluebook(name))
    end
  end

  describe "the table, held to the language" do
    def plan
      Hecks::Bluebook::MetaValidator::Plan.for(
        Hecks::Bluebook::MetaValidator.grammar_registry
      )
    end

    # Entity-owned categories (Member, Dispatch) have no top-level aggregate; they hang off
    # their owner's `.entities`, which may itself be entity-owned.
    def construct_for(meta, category, declared)
      return meta.aggregate(category) unless declared.entity_owned

      owner_plan = plan.category(declared.parent)
      owner      = construct_for(meta, declared.parent, owner_plan)
      owner.entities.find { |piece| piece.hecks_name == category }
    end

    def stored_fields(meta, category)
      declared  = plan.category(category)
      aggregate = construct_for(meta, category, declared)

      (aggregate.attributes.map(&:name) +
       declared.fields.map(&:to_sym) +
       declared.appends.keys.map(&:to_sym) +
       declared.setters.flat_map { |setter| setter.targets.keys.map(&:to_sym) })
        .uniq
        # A parent pointer is derived from containment, not a contract; an explicit `as:` `_id`
        # stays data but is excluded the same way.
        .reject { |field| field.to_s.end_with?("_id") || field == declared.parent_key&.to_sym }
    end

    it "consumes or explicitly derives every field the language declares" do
      meta = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

      unclaimed = plan.names.flat_map do |category|
        contract = Hecks::Bluebook::Assembly.contract(category)

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
        Hecks::Bluebook::Assembly::CONTRACTS.key?(category)
      end

      expect(missing).to be_empty,
                         "the language declares #{missing.join(", ")} and the table has no contract for it"
    end

    # PARENT_POINTERS cannot be computed in lib without going circular, so it is derived here
    # from `Plan`'s parent keys plus every bare word a contract claims `:parent`.
    it "names exactly the parent pointers the language and the contracts state" do
      structural = plan.names.filter_map { |category| plan.category(category).parent_key&.to_sym }
      claimed    = Hecks::Bluebook::Assembly::CONTRACTS.values.flat_map do |contract|
        contract.derived.select { |field, kind| kind == :parent && !field.to_s.end_with?("_id") }.keys
      end

      expect(Hecks::Bluebook::Assembly::PARENT_POINTERS.sort).to eq((structural + claimed).uniq.sort)
    end

    # A bare `derived:` name list is a promise nobody holds, so each claim carries a kind that
    # can fail: `derived: %i[version]` would otherwise drop a field in silence.
    it "justifies every derived field with a claim that can be false" do
      keys = declaration_keys

      unjustified = plan.names.flat_map do |category|
        contract = Hecks::Bluebook::Assembly.contract(category)

        contract.derived.filter_map do |field, kind|
          fault = fault_in(category, contract, field, kind, keys)
          "#{category}##{field} claims #{kind.inspect} — #{fault}" if fault
        end
      end

      expect(unjustified).to be_empty,
                             "#{unjustified.size} derived claim(s) do not hold:\n  #{unjustified.join("\n  ")}"
    end

    # One place naming what each derived-claim kind must justify.
    def fault_in(category, contract, field, kind, keys)
      case kind
      when :parent
        return nil if Hecks::Bluebook::Assembly.parent_pointer?(field)

        "no parent names it — a pointer is a *_id or one of #{Hecks::Bluebook::Assembly::PARENT_POINTERS.inspect}"
      when :children
        # `field` is a plural collection name; ask the pluralizer rather than strip an "s"
        # ("dispatches" would become "dispatchs").
        child = plan.names.find { |name| Hecks::Naming.plural(Hecks::Naming.snake(name)) == field.to_s }
        return nil if plan.category(child)&.parent == category

        "no category #{child} is declared with #{category} as its parent"
      when :elsewhere
        return nil if Hecks::Bluebook::Assembly.elsewhere?(category, field)

        "elsewhere is allow-listed one at a time, and this is not on the list"
      when :walk
        # The walk supplies the field; it is only consumed if the ask orders by it.
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
        # Check the member too, so a mistyped one (`:directionn`) is caught.
        wanted = Array(target) + [kind[2]].compact
        absent = wanted.reject { |key| keys.include?(key) }
        absent.empty? ? nil : "nothing folds into #{absent.inspect} — no declaration carries those keys"
      else "no such kind"
      end
    end

    # Whether the category's own way back orders by the field, proving a walk-supplied field is
    # consumed. An entity-owned category has no `DeclaredIn` ask; its list order is the
    # consumer, so the field must be its positional identity.
    def ordered_by?(category, field)
      declared = plan.category(category)
      # An identity path like "position.value" claims for its head, "position".
      return declared.identity_paths.map { |path| path.to_s.split(".").first }.include?(field.to_s) if declared.entity_owned

      meta = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
      ask  = meta.aggregate(category)&.query("DeclaredIn")

      ask&.order_by&.field.to_s == field.to_s
    end

    # Every key a real reconstructed declaration carries; a fold must land on one.
    def declaration_keys
      @declaration_keys ||= ASSEMBLY_CORPUS.values.flat_map do |file|
        built = load_chapter(file).bluebook(File.basename(file, ".bluebook").capitalize) ||
                load_chapter(file).bluebooks.values.first
        keys_in(Hecks::Bluebook::MetaValidator.hold(built)[:declaration])
      end.uniq
    end

    def keys_in(node)
      case node
      when Hash  then node.keys + node.values.flat_map { |held| keys_in(held) }
      when Array then node.flat_map { |held| keys_in(held) }
      else []
      end
    end

    # Every list the language declares has a shaper that exists or a reader on the holder.
    it "offers every appendable list, by a shaper that exists or a reader on the holder" do
      unreadable = plan.names.flat_map do |category|
        contract = Hecks::Bluebook::Assembly.contract(category)

        plan.category(category).appends.keys.filter_map do |list|
          shaper = contract.shaper(list)
          unknown_shaper = shaper && !readings.include?(shaper)
          next "#{category}##{list} names shaper #{shaper} and Readings has no such method" if unknown_shaper
          next nil if shaper
          next nil if contract.holder.nil? || contract.answers?(list.to_sym)

          "#{category}##{list} has no shaper and #{contract.holder} does not answer to it"
        end
      end

      expect(unreadable).to be_empty,
                            "#{unreadable.size} list(s) the language declares cannot be offered:\n  " \
                            "#{unreadable.join("\n  ")}"
    end

    def readings = Hecks::Bluebook::MetaValidator::Readings.instance_methods(false)

    # Every `reads:` exception names a key that exists and a reader that exists.
    it "reads every declaration key by a reader that exists, for a key the table names" do
      meta    = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
      readers = Hecks::Bluebook::MetaValidator::Reconstruction.private_instance_methods(false) +
                Hecks::Bluebook::MetaValidator::Shapes.instance_methods(false)

      broken = plan.names.flat_map do |category|
        contract = Hecks::Bluebook::Assembly.contract(category)
        named    = contract.fields.values.map(&:first)

        Hash(contract.reads).filter_map do |key, spec|
          next "#{category}##{key} is read but no field declares it" unless named.include?(key)

          # `[:from, row_key]` names a row key, not a reader; it must be a category field.
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

    # Containment stays code: `Command.Declare` carries `aggregate_id` before `entity_id`, so
    # the plan says an entity has no children and a derived walk would need an exception.
    it "cannot derive an entity's children from the plan, which is why containment is code" do
      expect(plan.names.select { |name| plan.category(name).parent == "Entity" }).to be_empty
      expect(plan.category("Command").parent).to eq("Aggregate")
      expect(plan.category("Query").parent).to eq("Aggregate")
    end

    it "claims nothing the language does not declare" do
      # A contract for an undeclared category would be dead weight nothing exercises.
      declared = plan.names
      phantom  = Hecks::Bluebook::Assembly::CONTRACTS.keys - declared

      expect(phantom).to be_empty
    end
  end

  it "gives the assembled head a working graph, not just a bag of fields" do
    # The assembled aggregate must carry the verbs, fields and owned shapes the DSL builds.
    built     = load_chapter(ASSEMBLY_CORPUS.fetch("Pizzas")).bluebook("Pizzas")
    assembled = Hecks::Bluebook::Assembly.call(built.to_h)
    pizza     = assembled.aggregate("Order")

    expect(pizza.command("CreatePizza").creates?).to be(true)
    expect(pizza.command("AddTopping").acts_on).to be(pizza)
    expect(pizza.attributes.map(&:name)).to include(:name, :toppings)
    expect(pizza.value_object("Price").hecks_fqn).to eq("Pizzas::Order.Price")
  end

  it "gives an assembled reference a resolvable edge" do
    built     = load_chapter(ASSEMBLY_CORPUS.fetch("Banking")).bluebook("Banking")
    assembled = Hecks::Bluebook::Assembly.call(built.to_h)
    account   = assembled.aggregate("Account")

    expect(account.attribute(:customer).type.resolve)
      .to be(assembled.aggregate("Customer"))
  end
end

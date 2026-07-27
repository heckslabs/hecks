# CommandBuilder — evaluates a `command "AddTopping" do ... end` block.
#
# Everything a command does is DECLARED. There is no handler body, no `def
# call` — the runtime reads givens, mutations, and emissions straight off the
# IR. That is what makes the same declaration projectable to another language.
#
#   command "AddTopping" do
#     role "Chef"
#     goal "Customize a pizza with ingredients"
#     reference_to Pizza
#     attribute :name,   String
#     attribute :amount, Integer
#     given("max 10 toppings") { toppings.size < 10 }
#     then_set :toppings, append: { name: :name, amount: :amount }
#     emits "ToppingAdded"
#   end
module Hecksagain
  module Bluebook
    module DSL
      class CommandBuilder
        include AttributeCollector

        # `owner` is the aggregate this command belongs to. It is what lets
        # reference_to tell "act on THIS root" from "belongs to THAT one".
        def initialize(name, owner: nil)
          @name      = name
          @owner     = owner
          @givens    = []
          @mutations = []
          @emits     = []
        end

        def role(value) = @role = value
        def goal(value) = @goal = value

        # Marks the command as acting on an EXISTING instance, loaded by id.
        #
        # The BARE name, always. The const shim only fires for constants that do
        # not exist, so once any domain has installed a real class called Thing,
        # a later bluebook writing `reference_to Thing` receives that CLASS and
        # stringifies to "OtherDomain::Thing" — silently referring across
        # domains. A reference names a type, not whichever class happens to have
        # claimed the constant.
        # TWO DIFFERENT SENTENCES WEAR ONE KEYWORD.
        #
        #   reference_to Account    on Account.Debit   — act on THIS account
        #   reference_to Customer   on Account.Open    — the account BELONGS to
        #                                                this customer
        #
        # The first names the root the command operates on, so the runtime
        # must load it before running. The second is a pointer to another
        # root, which is an ATTRIBUTE — Evans is explicit that you reference
        # another aggregate by its identity, and an id is a field.
        #
        # Reading both as "acts on an existing instance" is what made
        # Account.Open refuse with "no Account with id …" : a creating command
        # was asked to load the thing it was about to create, because it
        # happened to say which customer it was for. Pizzas never caught it —
        # its creating command references nothing at all.
        def reference_to(type)
          demodulised = Naming.demodulise(type)
          raise Malformed, "#{@name}.reference_to names nothing" if demodulised.to_s.empty?

          return cross_reference(demodulised) unless demodulised.to_s == @owner.to_s

          if @references
            raise Malformed,
                  "#{@name} references #{@owner} twice — a command acts on ONE " \
                  "root ; the second would silently win and the first would " \
                  "still look declared"
          end

          @references = demodulised
        end

        private

        # A pointer to another root, carried by identity — the same shape an
        # aggregate-level `reference_to` takes.
        def cross_reference(target)
          attribute(:"#{Naming.snake(target)}_id", String)
        end

        public

        # The block is real Ruby and stays real Ruby ; Prism reads its source so
        # the same text can be evaluated by a runtime that has no Ruby in it.
        def given(description, &predicate)
          canonical = Ports::Extraction.canonical(predicate)

          # A rule has to SAY what it means and SURVIVE extraction. An
          # unreadable predicate is not a lenient rule — it is a rule that
          # cannot be evaluated by any target but this one, and a bluebook
          # carrying one would pass here and refuse nothing everywhere else.
          raise Malformed, "#{@name} has a given with no description" if description.to_s.empty?

          if canonical.to_s.empty?
            raise Malformed,
                  "#{@name}'s given #{description.inspect} did not survive " \
                  "extraction — its source could not be read, so no other " \
                  "runtime could ever evaluate it"
          end

          @givens << IR::Given.new(
            description: description,
            canonical:   canonical,
            predicate:   predicate
          )
        end

        # then_set :status,   to: :new_status              — replace
        # then_set :toppings, append: { name: :name }      — push onto a list
        # then_set :balance,  increment: :amount           — add to a count
        # then_set :balance,  decrement: :amount           — take from a count
        #
        # increment/decrement exist because a ledger is ARITHMETIC : banking
        # wrote `then_set :balance, to: :amount` for a credit — replacing the
        # balance with the deposit — because the language could not say "add".
        # Bending the domain to fit the interpreter is the inversion this
        # project exists to avoid, so the language grew instead.
        def then_set(target, to: nil, append: nil, increment: nil, decrement: nil)
          raise Malformed, "#{@name} has a then_set with no target" if target.to_s.empty?

          named = { set: to, append: append, increment: increment, decrement: decrement }
                  .reject { |_, source| source.nil? }

          if named.empty?
            raise Malformed,
                  "#{@name}'s then_set :#{target} names no operation — " \
                  "give it to:, append:, increment:, or decrement:"
          end

          if named.size > 1
            raise Malformed,
                  "#{@name}'s then_set :#{target} tries to #{named.keys.join(' and ')} " \
                  "at once — one mutation, one meaning"
          end

          op, source = named.first
          @mutations << IR::Mutation.new(target: target.to_sym, op: op, source: source)
        end

        def emits(event_name)
          raise Malformed, "#{@name} emits an unnamed event" if event_name.to_s.empty?

          @emits << event_name.to_s
        end

        def build
          IR::Command.new(
            name:       @name,
            role:       @role,
            goal:       @goal,
            attributes: attributes,
            givens:     @givens,
            mutations:  @mutations,
            emits:      @emits,
            references: @references
          )
        end

        def self.build(name, owner: nil, &block)
          builder = new(name, owner: owner)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end

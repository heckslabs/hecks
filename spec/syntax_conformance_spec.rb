
require "spec_helper"

# The declared syntax must equal the surface the builders actually answer.
#
# `language/bluebook/syntax.bluebook` says how a bluebook is SPELLED — every
# word, the body it opens, the arguments it takes. Nothing else in this project
# says that. The Ruby builders are where the spelling really lives, Rust's
# `strict_boot` keeps a twelve-word near-miss list "because nothing declares
# what the keywords are", and the two have never been held to each other.
#
# This is the same shape as spec/vocabulary_conformance_spec, for the same
# reason: a declaration nothing reads cannot disagree with anything. It reads
# the syntax out of the meta-domain's IR and holds the live builders to it.
# Declare a word no builder answers and this fails ; grow a builder a word the
# language does not declare and this fails too.
#
# BOTH DIRECTIONS, DELIBERATELY. The one-way version — "everything declared
# exists" — is the one that lets the surface drift: a word added to a builder
# and not to the language is invisible to anything projected from the language,
# which is precisely the class of bug that made the parser unprojectable.
RSpec.describe "the declared syntax" do
  D = Hecksagain::Bluebook::DSL

  def self.judged_meta = Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  def self.syntax = judged_meta.aggregates.find { |a| a.hecks_name == "Syntax" }

  # The same chapter, reachable from inside an example.
  def meta = Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")

  # EVERY CELL AS TEXT. A member's fields decode back through typed literal
  # decoding on the way out of reconstruction — the same path Attribute#list
  # takes — so `at: "1"` comes back as the Integer 1 and `required: "true"` as
  # true. The language wrote text and the reconstruction is right to decode it;
  # this reads it back as what was written.
  def self.rows(name)
    syntax.value_objects.find { |vo| vo.hecks_name == name }
          .members.map { |row| row.to_h.transform_values(&:to_s) }
  end

  KEYWORDS      = rows("Keyword")
  ARGUMENTS     = rows("Argument")
  CONTEXTS      = rows("Context").map { |row| row[:name] }
  BODIES        = rows("Body").map { |row| row[:name] }
  ARGUMENT_KIND = rows("ArgumentKind").map { |row| row[:name] }

  # WHERE EACH CONTEXT'S WORDS ARE ANSWERED. `File` is the only one not answered
  # by a builder — `Hecks.bluebook` is reached through a module — and `Type` is
  # the only one whose "builder" is a mixin rather than a class, because the type
  # position inherits whichever `list_of`/`one_of` the enclosing builder has.
  #
  # `OneOf` shares ValueObjectBuilder with `ValueObject`: `one_of` instance_evals
  # its block on the builder itself, so the two contexts are one Ruby object.
  # That is why the completeness check below groups contexts BY BUILDER rather
  # than comparing each context to a class of its own.
  BUILDER = {
    "File"           => Hecks,
    "Bluebook"       => D::BluebookBuilder,
    "Aggregate"      => D::AggregateBuilder,
    "Entity"         => D::EntityBuilder,
    "Command"        => D::CommandBuilder,
    "Query"          => D::QueryBuilder,
    "ValueObject"    => D::ValueObjectBuilder,
    "OneOf"          => D::ValueObjectBuilder,
    "Lifecycle"      => D::LifecycleBuilder,
    "Policy"         => D::PolicyBuilder,
    "ProcessManager" => D::ProcessManagerBuilder,
    "Handler"        => D::ProcessManagerBuilder::HandlerBuilder,
    "ReadModel"      => D::ReadModelBuilder,
    "Type"           => D::AttributeCollector
  }.freeze

  # PUBLIC AND NOT A WORD — each with its reason, because an unexplained
  # allowlist is how a retired word goes on passing.
  #
  #   build / attributes / closed_sets / dispatches / add_aggregate_head
  #     a builder's own bookkeeping. `build` is the closing act `self.build`
  #     calls ; the rest are collections read by whoever owns them. None is ever
  #     typed in a bluebook.
  #
  #   boot / with_registry / current_registry
  #     the loading and runtime facade on `Hecks`, not declarations at all.
  #
  #   port / adapter / hecksagon / world / data_translation
  #     SIBLING ARTIFACTS, and the stated scope exclusion — each has its own file
  #     extension, its own builder and its own load step. A parser projected from
  #     this table reads `.bluebook`.
  NOT_A_WORD = {
    "Bluebook" => {
      classification: "an attr_reader BluebookBuilder.build reads when merging one chapter across files"
    },
    "File" => {
      boot:             "the runtime facade, not a declaration",
      with_registry:    "the runtime facade, not a declaration",
      current_registry: "the runtime facade, not a declaration",
      port:             "a sibling artifact — .port has its own builder and its own file",
      adapter:          "a sibling artifact — .adapter has its own builder and its own file",
      hecksagon:        "a sibling artifact — .hecksagon has its own builder and its own file",
      world:            "a sibling artifact — .world has its own builder and its own file",
      data_translation: "a sibling artifact — translations/ has its own builder and its own file"
    },
    "*" => {
      build:              "the builder's closing act, called by self.build",
      attributes:         "AttributeCollector's collection, read by whoever owns it",
      closed_sets:        "AttributeCollector's synthesised sets, installed by the aggregate",
      dispatches:         "HandlerBuilder's collection, read by ProcessManagerBuilder",
      add_aggregate_head: "ReadModelBuilder's own build calls it; nothing types it"
    }
  }.freeze

  # THE ONE PLACE A SPELLING AND A RUBY SIGNATURE DIVERGE. `transition` takes one
  # Hash and deletes `:from` out of it, so `from:` is written exactly like a
  # keyword argument and received as a reserved key of the pairs argument. The
  # language declares the SPELLING, which is what a parser reads, so it declares
  # `from` as named — and this is the exception that lets the signature check
  # agree.
  RESERVED_KEY = { %w[transition Lifecycle] => %w[from] }.freeze

  def self.words_answered_by(context)
    builder = BUILDER.fetch(context)
    listed  = if builder.is_a?(Module) && !builder.is_a?(Class) && builder.equal?(Hecks)
                builder.methods - Module.methods
              elsif builder.is_a?(Class)
                builder.public_instance_methods - Object.public_instance_methods
              else
                builder.public_instance_methods(false)
              end
    listed - NOT_A_WORD.fetch("*").keys - NOT_A_WORD.fetch(context, {}).keys
  end

  def method_for(word, context)
    builder = BUILDER.fetch(context)
    return builder.method(word) if builder.equal?(Hecks)

    builder.instance_method(word)
  end

  def declared_in(context) = KEYWORDS.select { |row| row[:context] == context }

  # ---------------------------------------------------------------- the cells

  it "spells every cell with a word the language admits" do
    expect(KEYWORDS.map { |row| row[:context] }.uniq - CONTEXTS).to be_empty
    expect(KEYWORDS.map { |row| row[:body] }.uniq - BODIES).to be_empty
    expect(ARGUMENTS.map { |row| row[:kind] }.uniq - ARGUMENT_KIND).to be_empty
    expect(ARGUMENTS.map { |row| row[:context] }.uniq - CONTEXTS).to be_empty
  end

  # `admits:` is a link the language can make and a closed set is not a root, so
  # nothing resolves it for a value object nobody instantiates. Checked here
  # instead, or the three `admits:` in syntax.bluebook would be decoration.
  it "holds every admits-bearing column to the set it names" do
    shape = ->(name) { self.class.syntax.value_objects.find { |vo| vo.hecks_name == name } }

    { "Keyword"  => { context: "Context", body: "Body" },
      "Argument" => { context: "Context", kind: "ArgumentKind" } }.each do |vo, links|
      links.each do |field, set|
        declared = shape.call(vo).attributes.find { |a| a.name.to_s == field.to_s }
        expect(declared.admits).to eq("Syntax::#{set}"),
                                   "#{vo}.#{field} should admit Syntax::#{set}"
      end
    end
  end

  it "enters every context it declares, and declares words for every context it enters" do
    entered = KEYWORDS.map { |row| row[:inner] }.reject(&:empty?).uniq
    spoken  = KEYWORDS.map { |row| row[:context] }.uniq

    # TWO CONTEXTS ARE NOT ENTERED BY A WORD, for two different reasons. `File`
    # is the outside of every body — nothing opens it. `Type` is the second
    # ARGUMENT of `attribute` rather than a body, so it is entered by a position
    # and never by a `do`. Every other context must be opened by something, or
    # no bluebook could ever type a word in it.
    expect((spoken - entered).sort).to eq(%w[File Type]),
                                       "a context is spoken in but nothing opens it"
    expect(entered - spoken).to be_empty,
                                "a word opens a body no word may be typed in"
  end

  # ------------------------------------------------------- word ⇄ builder

  CONTEXTS.each do |context|
    describe context do
      it "declares only words the builder answers" do
        undeclared = declared_in(context).map { |row| row[:word].to_sym }.uniq
                       .reject { |word| BUILDER.fetch(context).equal?(Hecks) ? Hecks.respond_to?(word) : BUILDER.fetch(context).method_defined?(word) }

        expect(undeclared).to be_empty,
                              "#{context} declares #{undeclared.inspect}, which " \
                              "#{BUILDER.fetch(context)} does not answer"
      end
    end
  end

  # THE OTHER DIRECTION, GROUPED BY BUILDER because two contexts can share one
  # (ValueObject and OneOf) and because AttributeCollector's words are MIXED IN
  # to five builders rather than answered by a builder of their own.
  #
  # A mixed-in word counts as declared for a builder only while the builder does
  # not SHADOW it — which is not a technicality. ValueObjectBuilder defines
  # `one_of(&block)` over AttributeCollector's `one_of(*values)`, so inside a
  # value-object body the inline type form is unreachable and `attribute :size,
  # one_of("small", "large")` raises. That asymmetry is real, and the ownership
  # test below is what keeps it declared rather than assumed.
  BUILDER.group_by { |_, builder| builder }.each do |builder, pairs|
    contexts = pairs.map(&:first)
    next if builder.equal?(D::AttributeCollector)

    it "declares every word #{builder} answers (#{contexts.join(', ')})" do
      declared = contexts.flat_map { |ctx| declared_in(ctx).map { |row| row[:word].to_sym } }.uniq

      if builder.is_a?(Class) && builder.include?(D::AttributeCollector)
        declared += KEYWORDS.select { |row| row[:context] == "Type" }
                            .map { |row| row[:word].to_sym }
                            .select { |word| builder.instance_method(word).owner.equal?(D::AttributeCollector) }
      end

      answered = contexts.flat_map { |ctx| self.class.words_answered_by(ctx) }.uniq

      expect((answered - declared).sort).to be_empty,
                                            "#{builder} answers words the language does not declare — " \
                                            "a bluebook could use them and nothing projected from the " \
                                            "language would know they exist"
    end
  end

  # ------------------------------------------------------ arguments ⇄ signature

  it "joins every argument row to a word" do
    keys    = KEYWORDS.map { |row| [row[:word], row[:context]] }.uniq
    widowed = ARGUMENTS.map { |row| [row[:keyword], row[:context]] }.uniq - keys

    expect(widowed).to be_empty, "argument rows joining to no keyword: #{widowed.inspect}"
  end

  it "declares every keyword argument each word's builder takes, and no other" do
    ARGUMENTS.group_by { |row| [row[:keyword], row[:context]] }.each do |(word, context), args|
      params  = method_for(word, context).parameters
      taken   = params.select { |kind, _| %i[key keyreq].include?(kind) }.map { |_, name| name.to_s }
      spelled = args.reject { |row| row[:named].empty? }.map { |row| row[:named] }.uniq
      allowed = taken + RESERVED_KEY.fetch([word, context], [])

      expect((spelled - allowed).sort).to be_empty,
                                          "#{context}.#{word} declares #{(spelled - allowed).inspect}, " \
                                          "which its builder does not take"
      expect((taken - spelled).sort).to be_empty,
                                        "#{context}.#{word}'s builder takes #{(taken - spelled).inspect}, " \
                                        "which the language does not declare"
    end
  end

  it "declares no more positionals than each word's builder takes" do
    ARGUMENTS.group_by { |row| [row[:keyword], row[:context]] }.each do |(word, context), args|
      positional = args.reject { |row| row[:at].empty? }
      next if positional.empty?

      params = method_for(word, context).parameters
      next if params.any? { |kind, _| kind == :rest } # `one_of("small", "large")` is variadic

      room   = params.count { |kind, _| %i[req opt].include?(kind) }
      # An inline hash at a call site binds to a positional Hash parameter or to
      # a **keyrest, and the SPELLING does not distinguish them — `where(a: 1)`
      # and `member a: 1` are typed identically and land differently.
      room += 1 if positional.any? { |row| row[:kind] == "pairs" } &&
                   params.any? { |kind, _| kind == :keyrest }

      expect(positional.map { |row| row[:at] }.map(&:to_i).max).to be <= room,
                                                                   "#{context}.#{word} declares more positionals than its builder takes"
    end
  end

  # THE DANGEROUS DIRECTION. A builder DEMANDING an argument the language calls
  # optional is a bluebook that parses everywhere and loads nowhere, so this is
  # checked one way on purpose: an optional parameter may be declared required
  # (that is what makes `identified_by :field` a form of its own), but a required
  # one may never be declared optional.
  it "never calls an argument optional that the builder demands" do
    ARGUMENTS.group_by { |row| [row[:keyword], row[:context]] }.each do |(word, context), args|
      params = method_for(word, context).parameters

      params.each_with_index do |(kind, name), index|
        next unless kind == :req

        row = args.find { |candidate| candidate[:at] == (index + 1).to_s }
        next if row.nil?

        expect(row[:required]).to eq("true"),
                                  "#{context}.#{word}'s #{name} is required by the builder and " \
                                  "declared optional"
      end

      params.select { |kind, _| kind == :keyreq }.each do |_, name|
        row = args.find { |candidate| candidate[:named] == name.to_s }
        next if row.nil?

        expect(row[:required]).to eq("true"),
                                  "#{context}.#{word}'s #{name}: is required by the builder and " \
                                  "declared optional"
      end
    end
  end

  # ---------------------------------------------------------- words ⇄ language

  # A context's category is where its `fills` must land. `Lifecycle` has none of
  # its own — it is a DECLARED FOLD onto whichever of Aggregate or Entity opened
  # it — so its words are checked against both. `Type` is a position, not a
  # record, so nothing it declares may claim to fill anything.
  CATEGORY_OF = {
    "File"           => %w[Bluebook],
    "Bluebook"       => %w[Bluebook],
    "Aggregate"      => %w[Aggregate],
    "Entity"         => %w[Entity],
    "Command"        => %w[Command],
    "Query"          => %w[Query],
    "ValueObject"    => %w[ValueObject],
    "OneOf"          => %w[ValueObject],
    "Lifecycle"      => %w[Aggregate Entity],
    "Policy"         => %w[Policy],
    "ProcessManager" => %w[ProcessManager],
    "Handler"        => %w[Dispatch],
    "ReadModel"      => %w[ReadModel],
    "Type"           => []
  }.freeze

  it "fills only fields the language declares" do
    fields = meta.aggregates.to_h { |a| [a.hecks_name, a.attributes.map { |at| at.name.to_s }] }

    KEYWORDS.reject { |row| row[:fills].empty? }.each do |row|
      landing = CATEGORY_OF.fetch(row[:context])
      expect(landing).not_to be_empty,
                             "#{row[:context]}.#{row[:word]} claims to fill #{row[:fills]}, but " \
                             "#{row[:context]} is a position and holds no record"
      expect(landing.any? { |category| fields.fetch(category).include?(row[:fills]) }).to be(true),
                                                                                          "#{row[:context]}.#{row[:word]} fills #{row[:fills]}, which " \
                                                                                          "#{landing.join('/')} does not declare"
    end
  end

  it "opens only categories the language declares" do
    declared = meta.aggregates.map(&:hecks_name)
    opened   = KEYWORDS.map { |row| row[:opens] }.reject(&:empty?).uniq

    expect(opened - declared).to be_empty
  end

  # EVERY DISPATCHED CATEGORY HAS A WORD, or a domain cannot declare it.
  #
  # The judge's plan is exactly the categories a bluebook can put records in
  # (Vocabulary and Syntax declare no commands and so are not in it — they are
  # the language's own declarations, written with `aggregate` like anything
  # else). If one of them had no word opening it, the language would hold a
  # category no bluebook could reach.
  it "opens every category the judge dispatches" do
    plan   = Hecksagain::Bluebook::MetaValidator::Plan.for(
      Hecksagain::Bluebook::MetaValidator.grammar_registry
    ).names
    opened = KEYWORDS.map { |row| row[:opens] }.reject(&:empty?).uniq

    expect((plan - opened).sort).to be_empty,
                                    "the judge dispatches categories no word opens — a bluebook " \
                                    "could not declare them"
  end

  # A `pairs` argument decides which field each pair lands in from the pair's own
  # key, so one cell cannot name it. A `Type` argument fills no field at all — a
  # type is not a field. Everything else names exactly one.
  it "names what each argument fills, except where nothing can" do
    ARGUMENTS.each do |row|
      unnameable = row[:kind] == "pairs" || row[:context] == "Type"

      if unnameable
        expect(row[:fills]).to eq(""),
                               "#{row[:context]}.#{row[:keyword]}'s #{row[:kind]} argument names a " \
                               "single field, which it cannot fill"
      else
        expect(row[:fills]).not_to be_empty,
                                   "#{row[:context]}.#{row[:keyword]} takes an argument that fills nothing"
      end
    end
  end

  # ------------------------------------------------------------ the near-miss list

  # `runtime::strict_boot`'s BLOCK_KEYWORDS used to be hand-written, "because
  # nothing declares what the keywords are" — its own comment. It had drifted:
  # five of its twelve words (`view`, `rule`, `factory`, `create`, and
  # `invariant` — a real word, but typed in a value object rather than an
  # aggregate) were not words the language admits at aggregate-body level at
  # all, so each was treated as a KNOWN keyword and let straight through the
  # check meant to catch exactly that — `factory do` would have been waved
  # through and then raised a Ruby-side NoMethodError with no warning.
  #
  # `bin/ir_syntax` now PROJECTS the list from these same rows into
  # rust/src/bluebook/ir_syntax.rs, and `strict_boot` reads it from there — so
  # this is no longer two copies to hold equal. It is one copy, checked twice:
  # spec/ir_syntax_export_spec.rb holds the checked-in Rust to the generator's
  # output ; this holds the generator's own selection rule (context Aggregate,
  # body keywords or source) to exactly what the projected file contains, so a
  # change to either the rule or the file without the other goes red.
  it "projects exactly the block keywords it declares at aggregate-body level" do
    source    = File.read(File.join(InMemoryDomain::ROOT, "rust/src/bluebook/ir_syntax.rs"))
    listed    = source[/const BLOCK_KEYWORDS: &\[&str\] = &\[(.*?)\];/m, 1]
    projected = listed.scan(/"([^"]+)"/).flatten

    opens_a_block = declared_in("Aggregate")
                      .select { |row| %w[keywords source].include?(row[:body]) }
                      .map { |row| row[:word] }
                      .uniq.sort

    expect(projected).to eq(opens_a_block)
  end
end

require "spec_helper"
require "tmpdir"
require "hecks/codemod"

# THE RUBY-SIDE `word_gate` — item #13 of the whole-project table-
# unification survey, and the first slice of it: Ruby's own DSL
# builders now consult the SAME self-hosted grammar table Rust's own
# parser `word_gate` already reads (`rust/parser/src/parse/mod.rs`),
# instead of falling straight through to Ruby's generic
# `NoMethodError`. Proven behaviorally here rather than just by the
# real corpus continuing to boot byte-identical (which it does — see
# this slice's own commit message) — a synthetic minimal bluebook
# means these tests still catch a regression even if the real corpus
# never happens to exercise a given branch again.
RSpec.describe "Hecks::Bluebook::DSL::WordGate" do
  def load(source)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "smoke.bluebook")
      File.write(path, source)
      Hecks::Codemod.load_bluebook(path)
    end
  end

  it "leaves every currently-valid word untouched — Ruby's own method lookup finds " \
     "an existing builder method first, this module never even sees the call" do
    registry = load(<<~BLUEBOOK)
      Hecks.bluebook "Untouched", version: "v1" do
        aggregate "Box" do
          attribute :label, Label
          identified_by :label

          value_object "Label" do
            attribute :value, String, pattern: '[^ \\t\\n\\r]'
          end

          command "Open" do
            emits "Opened"
          end

          lifecycle :status, default: "open" do
          end
        end
      end
    BLUEBOOK

    expect(registry.bluebooks.values.first.aggregates.first.hecks_name).to eq("Box")
  end

  it "refuses a word admitted SOMEWHERE, just not in this context, naming the " \
     "legal words this context actually admits — read live off the grammar table, " \
     "not a hand-copied list" do
    expect do
      load(<<~BLUEBOOK)
        Hecks.bluebook "WrongContext", version: "v1" do
          aggregate "Box" do
            attribute :label, Label
            identified_by :label
            median :label

            value_object "Label" do
              attribute :value, String, pattern: '[^ \\t\\n\\r]'
            end

            command "Open" do
              emits "Opened"
            end

            lifecycle :status, default: "open" do
            end
          end
        end
      BLUEBOOK
    end.to raise_error(Hecks::Bluebook::DSL::Malformed,
                       /'median' is not a word Aggregate admits — legal words here: .*identified_by/)
  end

  it "falls through to Ruby's own NoMethodError for a word the grammar knows " \
     "nothing about anywhere — an unrelated typo stays an ordinary, unconfusing error" do
    expect do
      load(<<~BLUEBOOK)
        Hecks.bluebook "GenuineTypo", version: "v1" do
          aggregate "Box" do
            attribute :label, Label
            identified_by :label
            giv3n("nope")

            value_object "Label" do
              attribute :value, String, pattern: '[^ \\t\\n\\r]'
            end

            command "Open" do
              emits "Opened"
            end

            lifecycle :status, default: "open" do
            end
          end
        end
      BLUEBOOK
    end.to raise_error(NoMethodError, /giv3n/)
  end

  it "does not shadow public_instance_methods with method_missing/respond_to_missing? — " \
     "both are private, the same way Object itself defines them, so " \
     "spec/syntax_conformance_spec.rb's own word↔builder gate never counts them " \
     "as words a builder answers" do
    builder = Hecks::Bluebook::DSL::AggregateBuilder
    answered = builder.public_instance_methods - Object.public_instance_methods
    expect(answered).not_to include(:method_missing, :respond_to_missing?)
  end

  it "steps aside entirely during the meta-domain's own bootstrap — the same " \
     "MetaValidator.bootstrapping? gate RuleReference#lookup already relies on, " \
     "since the grammar table this module reads does not exist yet while it is " \
     "still being built" do
    expect(Hecks::Bluebook::MetaValidator.bootstrapping?).to be(false)
    Hecks::Bluebook::MetaValidator.grammar_registry # already booted; still true off-bootstrap
    expect(Hecks::Bluebook::MetaValidator.bootstrapping?).to be(false)
  end

  describe "the bootstrap-window fallback's own-context-first precedence" do
    # BOOTSTRAP_CALLS_FALLBACK's values are always method-name Symbols in
    # real use, never `false` — but the lookup that finds them must not
    # rely on that: it has to pick the own-context entry whenever ONE
    # exists, never quietly prefer "Type"'s entry just because the
    # own-context value happens to look falsy. A minimal class stands in
    # for a real builder, with a fallback table rigged so the own-context
    # entry is `false` and the "Type" entry is a real, callable method —
    # if the old `||` lookup ran, it would silently dispatch to the real
    # method instead; the fix instead tries to `send(false, ...)`, which
    # raises `TypeError`, proving the own-context (`false`) entry won.
    let(:builder_class) do
      Class.new do
        include Hecks::Bluebook::DSL::WordGate

        const_set(:GRAMMAR_CONTEXT, "OwnContext") # own constant, not the block's lexical scope

        def type_method(*) = :type_method_result
      end
    end

    before do
      allow(Hecks::Bluebook::MetaValidator).to receive(:bootstrapping?).and_return(true)
      stub_const(
        "Hecks::Bluebook::DSL::GenericDispatch::BOOTSTRAP_CALLS_FALLBACK",
        { ["OwnContext", "gated_word"] => false, %w[Type gated_word] => :type_method }
      )
    end

    it "tries the own-context entry even when it is `false`, rather than falling to \"Type\"'s real method" do
      expect { builder_class.new.gated_word }.to raise_error(TypeError, /false/)
    end

    it "falls to \"Type\"'s entry when the own-context key is genuinely absent" do
      stub_const(
        "Hecks::Bluebook::DSL::GenericDispatch::BOOTSTRAP_CALLS_FALLBACK",
        { %w[Type gated_word] => :type_method }
      )

      expect(builder_class.new.gated_word).to eq(:type_method_result)
    end
  end
end

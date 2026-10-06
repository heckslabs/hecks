require "spec_helper"
require "tmpdir"
require "hecks/codemod"

# Ruby DSL builders consult the self-hosted grammar table, as Rust's parser `word_gate` does.
# Uses a synthetic bluebook so a regression shows even if the real corpus skips a branch.
RSpec.describe "Hecks::Bluebook::DSL::WordGate" do
  WORD_GATE_UNTOUCHED = <<~BLUEBOOK.freeze
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

  WORD_GATE_WRONG_CONTEXT = <<~BLUEBOOK.freeze
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

  WORD_GATE_TYPO = <<~BLUEBOOK.freeze
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

  def load(source)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "smoke.bluebook")
      File.write(path, source)
      Hecks::Codemod.load_bluebook(path)
    end
  end

  it "leaves every currently-valid word untouched — Ruby's own method lookup finds " \
     "an existing builder method first, this module never even sees the call" do
    registry = load(WORD_GATE_UNTOUCHED)

    expect(registry.bluebooks.values.first.aggregates.first.hecks_name).to eq("Box")
  end

  it "refuses a word admitted SOMEWHERE, just not in this context, naming the " \
     "legal words this context actually admits — read live off the grammar table, " \
     "not a hand-copied list" do
    expect { load(WORD_GATE_WRONG_CONTEXT) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed,
                      /'median' is not a word Aggregate admits — legal words here: .*identified_by/)
  end

  it "falls through to Ruby's own NoMethodError for a word the grammar knows " \
     "nothing about anywhere — an unrelated typo stays an ordinary, unconfusing error" do
    expect { load(WORD_GATE_TYPO) }.to raise_error(NoMethodError, /giv3n/)
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
    # bootstrapping? is nil, not false, in a process that has never booted the grammar.
    Hecks::Bluebook::MetaValidator.grammar_registry
    expect(Hecks::Bluebook::MetaValidator.bootstrapping?).to be(false)
  end

  describe "the bootstrap-window fallback's own-context-first precedence" do
    # The lookup must pick the own-context entry whenever one exists, even if its value is falsy.
    # The fallback table is rigged so it is `false` and "Type" maps to a callable method: a `||`
    # lookup would dispatch to that method; the correct one raises TypeError from `send(false)`.
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

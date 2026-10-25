require_relative "vocabulary"

module Hecks
  # The domain saying no: the parent of every class `Runtime::DOMAIN_REFUSALS` names, so a
  # driving adapter can `rescue Hecks::Refused` instead of splatting the list. A runtime fault
  # (`Runtime::StaleWrite`, `Runtime::WiringError`) is not one.
  #
  # What sort of no it is (`kind`) and which point of dispatch it came from (`stage`) are rows of
  # the language's `RefusalClass` vocabulary table, so Ruby, Rust and every client read one table.
  class Refused < StandardError
    # The `RefusalClass` rows by refusal name.
    CLASSES = Hecks::Vocabulary.rows("RefusalClass").to_h { |row| [row["refusal"], row] }.freeze

    # What a refusal that is not a named domain refusal (the base class, an adapter's narrowing of
    # one it does not name) is classed as.
    DEFAULT_CLASS = { "kind" => "refused", "stage" => "state" }.freeze

    # The last constant name of a class's path, such as `NotFound` of `Hecks::Runtime::NotFound`.
    LAST_NAME = /\w+\z/

    # @return [Symbol, nil] the attribute the refusal is about, when it is about one; the
    #   first in sorted order when it names several
    attr_reader :attribute

    # @return [String, nil] the text of the rule that refused (a `given`, `ensures` or invariant)
    attr_reader :rule

    # @param message [String, nil] the refusal text
    # @param attribute [Symbol, String, nil] the attribute the refusal is about, if any
    # @param rule [String, nil] the description of the rule that refused, if a rule did
    # @param stage [Symbol, String, nil] a narrower stage than the refusal's class implies
    # @param path [String, nil] a JSON Pointer to the offending value; `/attribute` when omitted
    def initialize(message = nil, attribute: nil, rule: nil, stage: nil, path: nil)
      super(message)
      @attribute = attribute&.to_sym
      @rule      = rule
      @stage     = stage&.to_sym
      @path      = path
    end

    # What sort of no this is, for an adapter that answers a missing record or a caller who lacks
    # a role differently from a rule that did not hold.
    #
    # @return [Symbol] one of the `RefusalKind` vocabulary rows; `:refused` for a broken rule
    def kind = classification["kind"].to_sym

    # The point of dispatch the refusal came from.
    #
    # @return [Symbol] one of the `DispatchStage` vocabulary rows
    def stage = @stage || classification["stage"].to_sym

    # The same refusal, placed inside an attribute of the command: a field refused within a value
    # object is about the value object's attribute, at the path that leads to the field.
    #
    # @param name [Symbol, String] the command attribute the refusal came from
    # @return [Hecks::Refused] this refusal if it is already about `name`, else a re-rooted copy
    def within(name)
      return self if @attribute == name.to_sym

      inner = path
      dup.tap do |copy|
        copy.attribute = name.to_sym
        copy.path = "/#{name}#{inner}"
      end
    end

    # @return [String, nil] a JSON Pointer to the offending value, such as `/balance/cents`
    def path = @path || (@attribute && "/#{@attribute}")

    # The refusal as plain data, the shape every client receives.
    #
    # @return [Hash{Symbol => Object}] kind, stage, attribute, path, rule and message
    def to_h
      { kind: kind, stage: stage, attribute: attribute, path: path, rule: rule, message: message }
    end

    protected

    attr_writer :attribute, :path

    private

    def classification
      self.class.ancestors.each do |ancestor|
        row = CLASSES[short_name(ancestor)]
        return row if row
      end
      DEFAULT_CLASS
    end

    def short_name(klass) = klass.to_s[LAST_NAME]
  end
end

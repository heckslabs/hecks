module ParserDifferential
  # The edits the differential fuzzer applies to a bluebook, all driven by one seeded `Random`.
  module Mutations
    WORDS = %w[aggregate command attribute sets given invariant policy on trigger lifecycle transition
               query where limit order_by read_model group_by entity value_object one_of member emits
               needs role goal String Integer Float Boolean list_of reference_to identified_by].freeze
    ODD   = ["\0", "é", "\u{1F4A5}", "\t", "\\", "'", ":", "->", "99999999999999999999", "-0.0e99", "{",
             "}"].freeze
    TYPES = %w[String Integer Float Boolean Date].freeze

    # Each edit takes `(random, text)` and answers the edited text; every one tolerates any input.
    BREAKING = [
      ->(random, text) { drop_line(random, text) },
      ->(random, text) { repeat_line(random, text) },
      ->(random, text) { swap_lines(random, text) },
      ->(random, text) { text[0, random.rand(text.size + 1)] },
      ->(random, text) { splice(random, text, ODD.sample(random: random)) },
      ->(random, text) { splice(random, text, " #{WORDS.sample(random: random)} ") },
      ->(random, text) { text.sub(/\b(?:#{TYPES.join("|")})\b/) { TYPES.sample(random: random) } },
      ->(random, text) { text.sub(/\d+/) { random.rand(1..9).to_s * random.rand(1..30) } },
      ->(random, text) { text.sub(/:(\w+)/) { ":#{WORDS.sample(random: random)}" } }
    ].freeze

    # Edits that cannot change a bluebook's meaning, so both parsers must still accept it and
    # print the same ir.json.
    BENIGN = [
      ->(random, text) { insert_line(random, text, "  # #{WORDS.sample(random: random)} note\n") },
      ->(random, text) { insert_line(random, text, "\n") },
      ->(random, text) { text.gsub(/(?<=\S)$/) { random.rand(4).zero? ? "  " : "" } },
      ->(random, text) { text.gsub("Widget", "Gadget#{random.rand(100)}") },
      ->(_random, text) { text.gsub(/^(\s*)attribute :/) { "#{Regexp.last_match(1)}attribute  :" } }
    ].freeze

    module_function

    def mutate(random, text) = apply(BREAKING, random, text)

    def benign(random, text) = apply(BENIGN, random, text)

    def apply(edits, random, text)
      Array.new(1 + random.rand(3)).reduce(text) { |memo, _| edits.sample(random: random).call(random, memo) }
    end

    def splice(random, text, piece) = text.dup.insert(random.rand(text.size + 1), piece)

    def insert_line(random, text, line) = text.lines.insert(random.rand(text.lines.size + 1), line).join

    def drop_line(random, text)
      lines = text.lines
      lines.empty? ? text : lines.tap { |all| all.delete_at(random.rand(all.size)) }.join
    end

    def repeat_line(random, text)
      lines = text.lines
      lines.empty? ? text : lines.insert(random.rand(lines.size), lines.sample(random: random)).join
    end

    def swap_lines(random, text)
      lines = text.lines
      return text if lines.size < 2

      first = random.rand(lines.size)
      second = random.rand(lines.size)
      lines[first], lines[second] = lines[second], lines[first]
      lines.join
    end

    # A plausible bluebook built from the grammar, so mutation starts from shapes the fixtures lack.
    def generate(random, chapter)
      aggregates = Array.new(1 + random.rand(3)) { |index| aggregate(random, index) }
      "Hecks.bluebook \"#{chapter}\" do\n#{aggregates.join}end\n"
    end

    def aggregate(random, index)
      count = 1 + random.rand(3)
      attributes = Array.new(count) { |n| "    attribute :f#{n}, V#{n}\n" }
      objects = Array.new(count) { |n| value_object(random, n) }
      commands = Array.new(random.rand(3)) { |n| command(random, n) }
      "  aggregate \"Widget#{index}\" do\n    identified_by :f0\n#{[attributes, objects, commands].join}  end\n"
    end

    def value_object(random, index)
      "    value_object \"V#{index}\" do\n      attribute :value, #{TYPES.sample(random: random)}\n    end\n"
    end

    def command(random, index)
      sets = random.rand(2).zero? ? "      sets :f0\n" : ""
      "    command \"Do#{index}\" do\n      attribute :f0, V0\n#{sets}    end\n"
    end
  end
end

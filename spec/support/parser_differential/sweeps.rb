module ParserDifferential
  # Seeded runs of the differential fuzzer; each answers the problems it found, empty when sound.
  module Sweeps
    module_function

    # Compares `text` as a one-off file and answers the result.
    def compare_text(dir, name, text, chapter = ParserDifferential.chapter_of(text))
      path = File.join(dir, "#{name}.bluebook")
      File.binwrite(path, text)
      ParserDifferential.compare(path, chapter)
    end

    # Generated bluebooks, bare and then after benign edits, must print identical ir.json from both
    # parsers. Answers one line per disagreement.
    def generated_problems(seed: ParserDifferential.seed, rounds: ParserDifferential.rounds)
      random = Random.new(seed)
      Dir.mktmpdir("parser_differential") do |dir|
        Array.new(rounds / 4) { |round| generated_round(random, dir, seed, round) }.flatten.compact
      end
    end

    def generated_round(random, dir, seed, round)
      text = Mutations.generate(random, "Gen#{round}")
      [text, Mutations.benign(random, text)].map.with_index do |source, edit|
        result = compare_text(dir, "gen_#{round}_#{edit}", source, "Gen#{round}")
        disagreement(seed, round, result, source) unless result.relation == :both_ok_same
      end
    end

    # Mutated generated bluebooks and fixtures; answers `[tally by relation, problem lines]`.
    def mutation_sweep(seed: ParserDifferential.seed, rounds: ParserDifferential.rounds)
      random = Random.new(seed)
      rows = Dir.mktmpdir("parser_differential") do |dir|
        Array.new(rounds) { |round| mutation_round(random, dir, round) }
      end
      problems = rows.each_with_index.reject { |(result, _text), _round| ParserDifferential.acceptable?(result) }
      [rows.map { |result, _text| result.relation }.tally,
       problems.map { |(result, text), round| disagreement(seed, round, result, text) }]
    end

    def mutation_round(random, dir, round)
      text = Mutations.mutate(random, mutation_base(random))
      [compare_text(dir, "mutated_#{round}", text), text]
    end

    def mutation_base(random)
      return Mutations.generate(random, "Gen") unless random.rand(3).zero?

      File.read(FIXTURES.sort.sample(random: random))
    end

    def disagreement(seed, round, result, text)
      "seed=#{seed} round=#{round}: #{result.relation} rust=#{result.rust.detail.inspect[0, 300]} " \
        "ruby=#{result.ruby.detail.inspect[0, 300]}\n#{text}"
    end
  end
end

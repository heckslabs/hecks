require "tempfile"
require "prism"
require_relative "postgres_probe"

# Executable documentation: a guide's fenced examples run against the real runtime.
# A guide that lies goes red in CI.
#
# Fences: `ruby bluebook` (a domain, booted), `ruby boot` (wiring), `ruby` (usage, one shared
# binding per guide), `ruby skip` (never run); hidden setup lives in `<!-- doctest:boot ... -->`.
# Claims sit on one line so failures name the true line: `expr # => value` asserts equality,
# `expr # ~> Klass: text` must raise that class (demodulized) with that message substring.
# A guide whose first line is `<!-- doctest: postgres -->` skips cleanly without a local Postgres.
module Doctest
  class Mismatch < StandardError
  end

  class Malformed < StandardError
  end

  Block = Struct.new(:kind, :code, :line, keyword_init: true)
  # `skip_fences` counts the dropped `ruby skip` fences; doc_skip_fence_caps_spec.rb caps it.
  Guide = Struct.new(:path, :blocks, :postgres, :skip_fences, keyword_init: true)

  # A method, not a constant: a constant would connect to Postgres on every run, `io: true` or not.
  def self.postgres_available? = PostgresProbe.available?

  # schema-evolution.md reads pizzas' real era-1→2 history out of Postgres; a fresh database
  # has the schema but not the history, so check for the second era's row. Memoized.
  def self.pizzas_history_available?
    return @pizzas_history_available if defined?(@pizzas_history_available)

    @pizzas_history_available = postgres_available? && pizzas_era_count >= 2
  end

  # @return [Integer] how many eras the pizzas database has recorded; 0 when it cannot be read
  def self.pizzas_era_count
    db = PG.connect(dbname: "hecks_pizzas")
    count = db.exec("SELECT count(*) FROM hecks_eras").getvalue(0, 0).to_i
    db.close
    count
  rescue PG::Error
    0
  end
  private_class_method :pizzas_era_count

  module_function

  # Reads a guide's fenced blocks, one line at a time.
  class GuideParser
    # @param path [String] the guide to read
    def initialize(path)
      @path = path
      @blocks = []
      @fence = nil
      @buffer = []
      @start = nil
      @skip_fences = 0
    end

    # @return [Doctest::Guide] the guide's blocks and its postgres and skip-fence markers
    def call
      File.read(@path).each_line.with_index(1) { |line, number| consume(line, number) }
      Guide.new(path: @path, blocks: @blocks, skip_fences: @skip_fences,
                postgres: File.foreach(@path).first(3).any? { |l| l.include?("<!-- doctest: postgres -->") })
    end

    private

    def consume(line, number)
      @fence ? continue_fence(line) : open_fence(line, number)
    end

    def continue_fence(line)
      return @buffer << line unless line.strip == (@fence == :hidden_boot ? "-->" : "```")

      close_fence
    end

    def close_fence
      unless %i[skip ignore].include?(@fence)
        kind = @fence == :hidden_boot ? :boot : @fence
        @blocks << Block.new(kind: kind, code: @buffer.join, line: @start)
      end
      @fence = nil
      @buffer = []
    end

    def open_fence(line, number)
      fence = opening(line.rstrip)
      return unless fence

      @fence = fence
      @start = number + 1
      @skip_fences += 1 if fence == :skip
    end

    def opening(text)
      case text
      when "```ruby bluebook"     then :bluebook
      when "```ruby boot"         then :boot
      when "```ruby"              then :usage
      when "```ruby skip"         then :skip
      when "<!-- doctest:boot"    then :hidden_boot
      when /\A```/                then :ignore
      end
    end
  end

  def parse(path) = GuideParser.new(path).call

  # Facade constants install onto Object and are never uninstalled, so two guides inventing the
  # same chapter would rebind to whichever booted last. Only `Hecks.bluebook "Name"` counts;
  # loading a shared corpus file declares nothing here.
  def declared_domains(guide)
    guide.blocks
         .reject { |block| block.kind == :usage }
         .flat_map { |block| block.code.scan(/Hecks\.bluebook[( ]\s*"([^"]+)"/) }
         .flatten.uniq
  end

  # Parses the guide at `path` and runs all of its blocks against a fresh boot.
  #
  # @raise [Doctest::Mismatch] if an `# =>` or `# ~>` claim does not hold
  # @raise [Doctest::Malformed] if a claim marker sits on an expression that does not parse alone
  def run(path)
    guide = parse(path)
    session = Session.new(guide)
    session.call
  end

  # Runs a guide in waves: each run of declaration blocks boots a runtime, and the usage
  # blocks after it run against that boot. Locals persist across waves, but a later wave's
  # boot rebinds `runtime`.
  class Session
    def initialize(guide)
      @guide = guide
      @tempfiles = []
    end

    # @raise [Doctest::Mismatch] if an `# =>` or `# ~>` claim does not hold
    # @raise [Doctest::Malformed] if a claim marker sits on an expression that does not parse alone
    def call
      shared = shared_binding
      waves.each do |declarations, usages|
        @runtime = boot(declarations) unless declarations.empty?
        usages.each { |block| eval(transform(block), shared, @guide.path, block.line) }
      end
      true
    ensure
      @tempfiles.each(&:close!)
    end

    private

    # The binding every usage block runs in: it answers `runtime` and holds the claim checker.
    def shared_binding
      @runtime = nil
      reader = -> { @runtime }
      host = Object.new
      host.define_singleton_method(:runtime) { reader.call }
      shared = host.instance_eval { binding }
      shared.local_variable_set(:__dt__, Checker.new(@guide.path))
      shared
    end

    def waves
      grouped = @guide.blocks.chunk_while do |before, after|
        !(before.kind == :usage && after.kind != :usage)
      end
      grouped.map do |blocks|
        [blocks.reject { |b| b.kind == :usage }, blocks.select { |b| b.kind == :usage }]
      end
    end

    def boot(declarations)
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        load_adapters
        declarations.each { |block| declare(block) }
      end
      registry.verify!
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end

    def load_adapters
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(InMemoryDomain::POSTGRES_ERA_ADAPTER) if @guide.postgres
    end

    def declare(block)
      return Kernel.eval(block.code, TOPLEVEL_BINDING, @guide.path, block.line) unless block.kind == :bluebook

      # Prism memoises extraction per path, so each block needs a fresh file.
      file = Tempfile.new(["doctest-", ".bluebook"])
      file.write(block.code)
      file.flush
      @tempfiles << file
      Kernel.eval(block.code, TOPLEVEL_BINDING, file.path, 1)
    end

    # One line stays one line, so backtraces name the guide's true line.
    def transform(block)
      block.code.each_line.with_index.map do |line, index|
        transform_line(line, block.line + index)
      end.join
    end

    def transform_line(line, number)
      if (match = line.match(/\A(?<code>.*\S)\s*#\s*=>\s*(?<expected>.+?)\s*\z/))
        single_line!(match[:code], number)
        equality_claim(match, number)
      elsif (match = line.match(/\A(?<code>.*\S)\s*#\s*~>\s*(?<klass>\w+)(?::\s*(?<message>.+?))?\s*\z/))
        single_line!(match[:code], number)
        refusal_claim(match, number)
      else
        line
      end
    end

    def equality_claim(match, number)
      "__dt__.eq(#{number}, #{match[:expected].dump}, #{match[:code].strip.dump}) { (#{match[:code]}) }\n"
    end

    def refusal_claim(match, number)
      "__dt__.refuses(#{number}, #{match[:klass].dump}, #{(match[:message] || "").dump}, " \
        "#{match[:code].strip.dump}) { (#{match[:code]}) }\n"
    end

    def single_line!(code, number)
      return if Prism.parse(code).success?

      raise Malformed,
            "#{@guide.path}:#{number}: a claim marker must sit on a single-line " \
            "expression — this line does not parse on its own"
    end
  end

  # Evaluates the `# =>` and `# ~>` claims, raising `Mismatch` with a readable diff. Only code
  # generated by `Session#transform` calls it.
  class Checker
    def initialize(path)
      @path = path
    end

    def eq(line, expected_source, expression)
      actual = yield
      expected = eval(expected_source, binding, "#{@path} (expected at :#{line})")
      return actual if actual == expected

      raise Mismatch, <<~WHY
        #{@path}:#{line}
          expr:     #{expression}
          expected: #{expected.inspect}
          actual:   #{actual.inspect}
      WHY
    end

    def refuses(line, klass, message, expression)
      yield
      raise no_refusal(line, klass, message, expression)
    rescue Mismatch
      raise
    rescue StandardError => e
      return e if e.class.name.to_s.split("::").last == klass && e.message.include?(message)

      raise wrong_refusal(line, klass, message, expression, e)
    end

    private

    def no_refusal(line, klass, message, expression)
      Mismatch.new(<<~WHY)
        #{@path}:#{line}
          expr:     #{expression}
          expected: a #{klass} refusal#{" (#{message})" unless message.empty?}
          actual:   no refusal at all
      WHY
    end

    def wrong_refusal(line, klass, message, expression, error)
      raised = error.class.name.to_s.split("::").last
      Mismatch.new(<<~WHY)
        #{@path}:#{line}
          expr:     #{expression}
          expected: #{klass}#{": #{message}" unless message.empty?}
          actual:   #{raised}: #{error.message}
      WHY
    end
  end
end

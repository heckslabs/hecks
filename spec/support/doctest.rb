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

    @pizzas_history_available =
      postgres_available? &&
      begin
        db = PG.connect(dbname: "hecks_pizzas")
        count = db.exec("SELECT count(*) FROM hecks_eras").getvalue(0, 0).to_i
        db.close
        count >= 2
      rescue PG::Error
        false
      end
  end

  module_function

  # rubocop:disable-next Metrics/CyclomaticComplexity
  def parse(path)
    blocks = []
    fence = nil
    buffer = []
    start = nil
    skip_fences = 0

    File.read(path).each_line.with_index(1) do |line, number|
      if fence
        if line.strip == (fence == :hidden_boot ? "-->" : "```")
          unless %i[skip ignore].include?(fence)
            kind = fence == :hidden_boot ? :boot : fence
            blocks << Block.new(kind: kind, code: buffer.join, line: start)
          end
          fence = nil
          buffer = []
        else
          buffer << line
        end
        next
      end

      case line.rstrip
      when "```ruby bluebook"     then fence = :bluebook
      when "```ruby boot"         then fence = :boot
      when "```ruby"              then fence = :usage
      when "```ruby skip"         then fence = :skip
      when "<!-- doctest:boot"    then fence = :hidden_boot
      when /\A```/                then fence = :ignore
      else next
      end
      start = number + 1
      skip_fences += 1 if fence == :skip
    end

    Guide.new(path: path, blocks: blocks, skip_fences: skip_fences,
              postgres: File.foreach(path).first(3).any? { |l| l.include?("<!-- doctest: postgres -->") })
  end

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
      host = Object.new
      checker = Checker.new(@guide.path)
      runtime = nil
      host.define_singleton_method(:runtime) { runtime }
      shared = host.instance_eval { binding }
      shared.local_variable_set(:__dt__, checker)

      waves.each do |declarations, usages|
        runtime = boot(declarations) unless declarations.empty?
        usages.each do |block|
          eval(transform(block), shared, @guide.path, block.line)
        end
      end
      true
    ensure
      @tempfiles.each(&:close!)
    end

    private

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
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(InMemoryDomain::POSTGRES_ERA_ADAPTER) if @guide.postgres

        declarations.each do |block|
          if block.kind == :bluebook
            # Prism memoises extraction per path, so each block needs a fresh file.
            file = Tempfile.new(["doctest-", ".bluebook"])
            file.write(block.code)
            file.flush
            @tempfiles << file
            Kernel.eval(block.code, TOPLEVEL_BINDING, file.path, 1)
          else
            Kernel.eval(block.code, TOPLEVEL_BINDING, @guide.path, block.line)
          end
        end
      end
      registry.verify!
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
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
        "__dt__.eq(#{number}, #{match[:expected].dump}, #{match[:code].strip.dump}) { (#{match[:code]}) }\n"
      elsif (match = line.match(/\A(?<code>.*\S)\s*#\s*~>\s*(?<klass>\w+)(?::\s*(?<message>.+?))?\s*\z/))
        single_line!(match[:code], number)
        "__dt__.refuses(#{number}, #{match[:klass].dump}, #{(match[:message] || "").dump}, " \
          "#{match[:code].strip.dump}) { (#{match[:code]}) }\n"
      else
        line
      end
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
      raise Mismatch, <<~WHY
        #{@path}:#{line}
          expr:     #{expression}
          expected: a #{klass} refusal#{" (#{message})" unless message.empty?}
          actual:   no refusal at all
      WHY
    rescue Mismatch
      raise
    rescue StandardError => e
      raised = e.class.name.to_s.split("::").last
      return e if raised == klass && e.message.include?(message)

      raise Mismatch, <<~WHY
        #{@path}:#{line}
          expr:     #{expression}
          expected: #{klass}#{": #{message}" unless message.empty?}
          actual:   #{raised}: #{e.message}
      WHY
    end
  end
end

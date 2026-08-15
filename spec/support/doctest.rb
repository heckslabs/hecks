require "tempfile"
require "prism"
require_relative "postgres_probe"

# EXECUTABLE DOCUMENTATION — a guide's fenced examples are extracted and
# run against the real runtime, so a guide that lies goes red in CI. The
# same covenant everything else in this codebase lives under: a
# declaration nothing reads cannot disagree with anything, and prose is
# a declaration.
#
# A guide is a Markdown file whose fences mean:
#
#   ```ruby bluebook   a domain declaration — booted, via its own
#                      Tempfile (Prism's extraction memoises per PATH,
#                      so every block gets a fresh one). Spelled
#                      "ruby bluebook", not bare "bluebook", so a
#                      public renderer (GitHub Pages' Rouge highlighter
#                      reads only the first info-string word) colors it
#                      as the real Ruby it is, the same reason
#                      "ruby boot" / "ruby skip" already do.
#   ```ruby boot       wiring — hecksagon/world blocks, still inside
#                      with_registry
#   ```ruby            usage — runs against the bound runtime, one
#                      shared binding per guide so locals carry across
#                      blocks the way a narrative expects
#   ```ruby skip       shown, never run
#
# and hidden setup lives in an HTML comment:
#
#   <!-- doctest:boot
#   Kernel.load(...)
#   -->
#
# Two claim markers, both required to sit on a SINGLE-LINE expression
# (the transform must preserve the file's line count so a failure names
# the guide's real line):
#
#   expr   # => expected      asserted with == against the expected
#                             text evaluated in the same binding
#   expr   # ~> Klass: text   the expression MUST refuse — class name
#                             (demodulized) and message substring both
#                             checked; not raising is the failure
#
# A guide whose first line is `<!-- doctest: postgres -->` runs only
# when a local Postgres answers, and skips cleanly otherwise.
module Doctest
  Mismatch = Class.new(StandardError)
  Malformed = Class.new(StandardError)

  Block = Struct.new(:kind, :code, :line, keyword_init: true)
  Guide = Struct.new(:path, :blocks, :postgres, keyword_init: true)

  # Shared with every other Postgres spec via support/postgres_probe.rb —
  # a real `PG.connect` round trip asking the identical question, not a
  # copy of the probe itself. A METHOD, not a constant — this module gets
  # `require_relative`d unconditionally by every doctest-running spec, so
  # a constant here would connect on every `bundle exec rspec`, `io: true`
  # excluded or not. Both callers below already only reach this from
  # inside an example body (already deferred by RSpec), so a method call
  # there triggers real I/O only when the example actually runs.
  def self.postgres_available? = PostgresProbe.available?

  # schema-evolution.md's opening section is not a fixture — it reads
  # `examples/pizzas`' own real era-1→2 migration back out of whatever
  # Postgres is reachable, on purpose (see the guide's own "It already
  # happened here" section for why faking that history would be a
  # larger dishonesty than skipping it). That real history exists on
  # exactly one machine: whoever's local Postgres lived through the
  # actual pizza migration. A fresh database — CI's, or anyone else's
  # first `createdb hecks_pizzas` — has the schema and none of the
  # history, so this checks for the second era's own row rather than
  # assume reachable Postgres means this specific guide can run. Also a
  # method, memoized, for the same reason `postgres_available?` is.
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

  def parse(path)
    blocks = []
    fence = nil
    buffer = []
    start = nil

    File.read(path).each_line.with_index(1) do |line, number|
      if fence
        if (fence == :hidden_boot ? line.strip == "-->" : line.strip == "```")
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
    end

    Guide.new(path: path, blocks: blocks,
              postgres: File.foreach(path).first(3).any? { |l| l.include?("<!-- doctest: postgres -->") })
  end

  # The chapter names a guide declares — the collision gate reads these,
  # because facade constants install onto Object and are never
  # uninstalled: two guides INVENTING the same domain would silently
  # rebind to whichever booted last, under random spec order.
  #
  # Only `Hecks.bluebook "Name" do ... end` counts as inventing one — a
  # guide that instead Kernel.loads a real corpus file (examples/pizzas,
  # examples/banking) and wires it with its own `hecksagon`/`world`
  # block never writes that chapter's OWN `Hecks.bluebook` line itself
  # (that line lives inside the loaded file, invisible to this scan), so
  # two guides sharing one real corpus example this way is safe and
  # deliberately not flagged: both boot the identical file into their
  # own isolated Registry, and there is nothing for them to disagree
  # about.
  def declared_domains(guide)
    guide.blocks
         .reject { |block| block.kind == :usage }
         .flat_map { |block| block.code.scan(/Hecks\.bluebook[( ]\s*"([^"]+)"/) }
         .flatten.uniq
  end

  def run(path)
    guide = parse(path)
    session = Session.new(guide)
    session.call
  end

  # A guide runs as WAVES: each run of declaration blocks boots one
  # session, and the usage blocks after it run against that boot. A
  # later declaration block starts the next wave — the README's shape,
  # where two independent narratives share one file. Locals persist
  # across waves (one shared binding), but a new wave's boot REBINDS the
  # runtime, so a guide reaches back to an earlier wave's domain at its
  # own peril.
  class Session
    def initialize(guide)
      @guide = guide
      @tempfiles = []
    end

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
          eval(transform(block), shared, @guide.path, block.line) # rubocop:disable Security/Eval
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
      registry = Hecksagain::Runtime::Registry.new
      Hecksagain.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(InMemoryDomain::POSTGRES_ADAPTER) if @guide.postgres

        declarations.each do |block|
          if block.kind == :bluebook
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
      Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
    end

    # Marker lines are rewritten IN PLACE — one line stays one line, so
    # every backtrace and failure names the guide's true line number.
    def transform(block)
      block.code.each_line.with_index.map { |line, index|
        transform_line(line, block.line + index)
      }.join
    end

    def transform_line(line, number)
      if (match = line.match(/\A(?<code>.*\S)\s*#\s*=>\s*(?<expected>.+?)\s*\z/))
        single_line!(match[:code], number)
        "__dt__.eq(#{number}, #{match[:expected].dump}, #{match[:code].strip.dump}) { (#{match[:code]}) }\n"
      elsif (match = line.match(/\A(?<code>.*\S)\s*#\s*~>\s*(?<klass>\w+)(?::\s*(?<message>.+?))?\s*\z/))
        single_line!(match[:code], number)
        "__dt__.refuses(#{number}, #{match[:klass].dump}, #{(match[:message] || '').dump}, #{match[:code].strip.dump}) { (#{match[:code]}) }\n"
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

  class Checker
    def initialize(path)
      @path = path
    end

    def eq(line, expected_source, expression)
      actual = yield
      expected = eval(expected_source, binding, "#{@path} (expected at :#{line})") # rubocop:disable Security/Eval
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
          expected: a #{klass} refusal#{message.empty? ? '' : " (#{message})"}
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
          expected: #{klass}#{message.empty? ? '' : ": #{message}"}
          actual:   #{raised}: #{e.message}
      WHY
    end
  end
end

# Fails a spec that reads the owner's state in the real home, past the sandbox's `HOME`: a path
# built from the account database or a literal home string. Best effort: it covers the common
# readers of `File` and `Dir`, not every route to a file. State the sandbox holds is never refused.
module RealHomeGuard
  # Raised when a spec reads the owner's real state.
  class Violation < StandardError; end

  # The state under the real home that one run must not see of another's.
  ROOTS = %w[.claude/hecks-dev .claude/hecks-train .claude/jobs .claude/projects .cache/hecks].freeze

  # The `File` readers watched, each taking the path first.
  FILE_READERS = %i[open new read binread readlines foreach exist? file? directory? stat mtime size zero?].freeze

  # The `Dir` readers watched, each taking the path first.
  DIR_READERS = %i[children entries each_child exist? glob []].freeze

  @inside_example = false

  # Watches only while an example runs: the runner that hosts the suite reads the owner's own
  # state outside it.
  #
  # @yield the example
  # @return [void]
  def self.during
    @inside_example = true
    yield
  ensure
    @inside_example = false
  end

  # @param path [Object] what a reader was given
  # @return [void]
  # @raise [Violation] when it names the owner's real state
  def self.check!(path)
    return unless @inside_example

    text = path.to_s
    return if text.empty? || text.include?("\0")

    expanded = resolve(text)
    return unless real?(expanded)

    raise Violation, "a spec read #{expanded}, state of the owner's real home; build it under the run's own " \
                     "directory (RunSandbox.path) instead"
  end

  # @param text [String] a path
  # @return [String] it made absolute, with symlinks followed when it exists
  def self.resolve(text)
    File.realpath(File.expand_path(text))
  rescue SystemCallError
    File.expand_path(text)
  end

  # @param expanded [String] an absolute path
  # @return [Boolean] whether it is under a watched root of the real home
  def self.real?(expanded)
    base = File.join(resolve(RunSandbox.real_home), "")
    ROOTS.any? { |root| expanded == File.join(base, root) || expanded.start_with?(File.join(base, root, "")) }
  end

  # Prepended to a singleton to check the path of each watched reader.
  #
  # @param names [Array<Symbol>] the readers
  # @return [Module]
  def self.watching(names)
    Module.new do
      names.each do |name|
        define_method(name) do |path = nil, *rest, **options, &block|
          RealHomeGuard.check!(path)
          super(path, *rest, **options, &block)
        end
      end
    end
  end
end

File.singleton_class.prepend(RealHomeGuard.watching(RealHomeGuard::FILE_READERS))
Dir.singleton_class.prepend(RealHomeGuard.watching(RealHomeGuard::DIR_READERS))

RSpec.configure { |config| config.around { |example| RealHomeGuard.during { example.run } } }

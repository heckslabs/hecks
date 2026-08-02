require "open3"

# The loading contract, made executable. Two facts hold across lib/:
#
#   1. Every file is SELF-SUFFICIENT — it requires what it references,
#      so it loads standalone, first, in an empty process. Nothing may
#      lean on some other file having loaded a dependency earlier.
#   2. The subsystem wrappers' require order is CONVENIENCE, not load
#      order — the whole framework loads with the wrappers reversed.
#
# Both used to be true only by accident of history: the flat require
# list in lib/hecksagain.rb encoded the order files were added in, and
# nothing would have named the moment a class-body constant reference
# quietly made that order load-bearing again. Now this spec names it,
# and the file it names is the one that grew the dependency.
RSpec.describe "load hygiene" do
  ROOT_DIR = File.expand_path("..", __dir__)
  LIB = File.join(ROOT_DIR, "lib")

  def load_in_subprocess(feature)
    Open3.capture3("ruby", "-I", LIB, "-e", "require #{feature.inspect}")
  end

  # bluebook/** file contents are frozen by standing constraint, so a
  # bluebook INTERNAL cannot grow the requires standalone loading needs
  # (`extend Construct` at class body, contract.rb before contracts.rb).
  # Their namespace files carry those requires instead — so the wrappers
  # ARE held to the standard, and the internals are exempt.
  BLUEBOOK_WRAPPERS = %w[
    hecksagain/bluebook hecksagain/bluebook/ir hecksagain/bluebook/dsl
    hecksagain/bluebook/expression
  ].freeze

  it "loads every lib file standalone, in a fresh process" do
    features = Dir[File.join(LIB, "hecksagain", "**", "*.rb")]
               .map { |file| file.sub("#{LIB}/", "").sub(/\.rb\z/, "") }
               .reject { |f| f.start_with?("hecksagain/bluebook/") && !BLUEBOOK_WRAPPERS.include?(f) }
               .sort

    failures = Queue.new
    work = Queue.new
    features.each { |feature| work << feature }
    8.times.map do
      Thread.new do
        until work.empty?
          feature = begin
            work.pop(true)
          rescue ThreadError
            break
          end
          _out, err, status = load_in_subprocess(feature)
          failures << "#{feature}:\n#{err.lines.first(3).join}" unless status.success?
        end
      end
    end.each(&:join)

    broken = [].tap { |list| list << failures.pop until failures.empty? }
    expect(broken).to be_empty,
                      "these files no longer load standalone — each needs to require what it references:\n\n" \
                      "#{broken.sort.join("\n")}"
  end

  it "loads the whole framework with the subsystem wrappers in reverse order" do
    wrappers = File.read(File.join(LIB, "hecksagain.rb"))
               .scan(%r{^require_relative "(hecksagain/[^"]+)"}).flatten

    script = wrappers.reverse.map { |wrapper| "require #{wrapper.inspect}" }.join("; ")
    _out, err, status = Open3.capture3("ruby", "-I", LIB, "-e", script)

    expect(status.success?).to be(true),
                               "reversing the wrapper order broke the load — an order-dependence " \
                               "crept back in:\n#{err.lines.first(5).join}"
  end
end

# frozen_string_literal: true

require "etc"
require "open3"

module Hecks
  # Runs generated Rust through rustfmt, so a generator writes what `cargo fmt --check` accepts.
  #
  # Every generator that writes a `.rs` file formats its text here before comparing it with the tree
  # or writing it, so a drift check and a write see the same bytes. The edition is pinned in the
  # call, not read from a `rustfmt.toml`, because a generator may run from any directory.
  module RustFormat
    # Raised when the rustfmt program cannot be found.
    class Missing < StandardError; end

    # Raised when rustfmt fails for a reason that is not the text: a toolchain that will not
    # install, say. Falling back to the unformatted text would write the wrong bytes without a word.
    class Failed < StandardError; end

    EDITION = "2021"

    # The most passes `call` makes; a text still changing after them keeps the last result.
    PASSES = 3

    # Serializes the rustfmt children of this process. In a whole-suite run, worker threads capturing
    # at once end with `Errno::EBADF` in `Open3.popen_run`, so each capture waits for this lock.
    SPAWN_LOCK = Mutex.new

    module_function

    # @param path [String] where the text will be written
    # @return [Boolean] whether the path is Rust source
    def rust?(path)
      path.to_s.end_with?(".rs")
    end

    # Formats one Rust source text.
    #
    # Text rustfmt cannot parse is returned as it came, with a warning on stderr: the compiler will
    # name the real fault, and a generator should not be the thing that hides it. Any other failure
    # of rustfmt raises, since the text is not the problem.
    #
    # @param text [String] Rust source
    # @return [String] the same source as rustfmt lays it out
    # @raise [Missing] when rustfmt is not installed
    # @raise [Failed] when rustfmt fails for a reason other than the text
    def call(text)
      PASSES.times do
        formatted = pass(text)
        return formatted if formatted == text

        text = formatted
      end
      text
    end

    # One rustfmt run. rustfmt does not always reach a fixed point in one pass, so `call` repeats it
    # until the text stops changing, as a later `cargo fmt --check` would have it.
    #
    # @param text [String] Rust source
    # @return [String] the source after one pass, or unchanged when rustfmt cannot parse it
    # @raise [Failed] when rustfmt fails for a reason other than the text
    def pass(text)
      out, err, status = SPAWN_LOCK.synchronize do
        Open3.capture3("rustfmt", "--edition", EDITION, "--emit", "stdout", stdin_data: text)
      end
      return out if status.success?
      raise Failed, "rustfmt failed: #{err.lines.first&.strip}" unless err.include?("<stdin>")

      warn "hecks: rustfmt could not format generated Rust, leaving it as generated: #{err.lines.first&.strip}"
      text
    rescue Errno::ENOENT
      raise Missing, "rustfmt is not installed: generated Rust is formatted with it; run `rustup component add rustfmt`"
    end

    # Formats the Rust texts of a path-to-text map and leaves the others alone.
    #
    # @param content [Hash{String => String}] absolute path to text
    # @return [Hash{String => String}] the same map with each `.rs` text formatted
    def files(content)
      rust = content.select { |path, _| rust?(path) }
      formatted = parallel_map(rust.values) { |text| call(text) }
      content.to_h { |path, text| [path, rust.key?(path) ? formatted.shift : text] }
    end

    # Maps `items` through the block on one thread per core. rustfmt runs as a child process, so
    # the threads wait on it rather than on the interpreter lock; order is kept.
    #
    # @param items [Array] the inputs
    # @return [Array] the block's result for each input, in order
    def parallel_map(items)
      results = Array.new(items.size)
      queue = closed_queue(items.size)
      workers = Array.new([Etc.nprocessors, items.size].min) do
        Thread.new { while (index = queue.pop) do results[index] = yield(items[index]) end }
      end
      workers.each(&:join)
      results
    end

    # @param size [Integer] how many indexes to hold
    # @return [Queue] the indexes 0...size, closed, so a pop past the last returns nil
    def closed_queue(size)
      Queue.new((0...size).to_a).tap(&:close)
    end
  end
end

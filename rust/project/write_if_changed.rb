require "fileutils"
require "set"

# THE ROOT CAUSE OF A REAL, MEASURED CI COST — every generated file this
# whole codegen pipeline writes (rust/src/generated/**, rust/Cargo.toml)
# used to be rewritten UNCONDITIONALLY on every regeneration, even when
# the bytes were identical to what was already on disk. A rewritten
# file's mtime changes regardless of content; Cargo's own incremental
# compiler reacts to that alone and does a full rebuild of everything
# downstream, whether or not the actual source changed. Measured live:
# regenerating and rebuilding the SAME domain's wasm artifact twice in a
# row, back to back, with genuinely byte-identical generated output both
# times, still cost ~45-49s on the SECOND call — no speedup at all, on a
# machine where the exact same `cargo build` with nothing touching the
# tree between calls is a 0.0s no-op.
#
# The fix belongs here, not in a cache layered on top of the generator:
# skip the write (and the mtime bump) whenever the content genuinely
# hasn't changed. Every call site that used to `File.write`/`File.open`
# directly now goes through this instead.
module RustProjection
  module WriteIfChanged
    module_function

    # THE OTHER HALF OF THIS FIX — every write site below skips a no-op
    # rewrite, but that alone is not enough while the CALLER still wipes
    # a whole directory before regenerating it (`FileUtils.rm_rf`,
    # bin/project_rust's own former discipline for exactly this reason:
    # an aggregate removed from a bluebook must not leave its old .rs
    # file behind, still compiling in). A wiped file never "already
    # exists with identical content" — every regeneration would report
    # "changed" regardless, defeating the point.
    #
    # `track_directory(dir) { ... regenerate, writing only through
    # .call/.block ... }` replaces wipe-then-regenerate with regenerate-
    # in-place-then-prune: every path written OR confirmed-unchanged
    # inside the block is recorded; once the block returns, anything
    # already in `dir` that was NEVER touched during it — the actual
    # orphan case the old rm_rf existed for — is deleted. A file that's
    # merely unchanged keeps its mtime (and Cargo's incremental cache);
    # a file nothing regenerated this run is still gone, same as before.
    #
    # Directories can nest — every write is recorded against every
    # currently-open ancestor, not just the innermost one, so tracking
    # an outer directory spanning several inner domains' own
    # directories still prunes each of them correctly.
    #
    # TWO FORMS: `track_directory(dir) { ... }` for the simple case
    # (everything relevant happens inside one block). `push_directory`/
    # `pop_and_prune` are the same thing split apart, for a caller whose
    # writes for one directory aren't adjacent in the source — this
    # generator's own bin/project_rust regenerates a domain's per-
    # aggregate files via one call, then writes that SAME directory's
    # `merged.rs` and appends to its `mod.rs` much later, with a few
    # hundred unrelated lines of cross-domain bookkeeping in between;
    # forcing all of that into one block would mean a much larger,
    # riskier restructure than the two extra call sites this needs.
    def track_directory(dir)
      push_directory(dir)
      yield
    ensure
      pop_and_prune(dir)
    end

    def push_directory(dir)
      FileUtils.mkdir_p(dir)
      stack.push([File.expand_path(dir), Set.new])
    end

    # Matches by directory, not strictly LIFO — `bin/project_rust`
    # interleaves the meta chapter's OWN open tracking (opened first,
    # closed last, after the target domain's own is opened AND closed
    # in between) with the target domain's, so plain stack-top popping
    # would close the wrong one.
    def pop_and_prune(dir)
      abs_dir = File.expand_path(dir)
      idx = stack.rindex { |tracked_dir, _| tracked_dir == abs_dir }
      return unless idx

      _dir, touched = stack.delete_at(idx)
      existing = Dir.glob(File.join(abs_dir, "*"))
      (existing - touched.to_a).each do |orphan|
        FileUtils.rm_rf(orphan)
        puts "pruned #{orphan} (no longer generated)"
      end
    end

    def stack
      Thread.current[:hecks_write_if_changed_stack] ||= []
    end
    private_class_method :stack

    def record_touch(path)
      abs = File.expand_path(path)
      stack.each do |dir, touched|
        touched << abs if abs.start_with?("#{dir}/")
      end
    end
    private_class_method :record_touch

    # `path` already exists with identical `content` — nothing to do,
    # nothing touched. Otherwise writes normally. Returns whether it
    # actually wrote, in case a caller wants to log/count real changes.
    def call(path, content)
      record_touch(path)
      # `.b` on BOTH sides — a caller building `content` via `File.read`
      # (text mode, UTF-8-tagged) compared against `File.binread`
      # (ASCII-8BIT) fails `==` even on byte-identical content: Ruby's
      # String#== is encoding-aware, not purely byte-for-byte, once the
      # two operands' encodings differ. Found live: rust/Cargo.toml's
      # own site read via `File.read`, reported "wrote" on every single
      # call regardless of content, same bytesize both sides, `==` still
      # false. `.b` (String#b) reinterprets a string's existing bytes as
      # ASCII-8BIT without re-encoding them, making this the actual byte
      # comparison it was always supposed to be.
      return false if File.exist?(path) && File.binread(path) == content.b

      File.write(path, content)
      true
    end

    # Same discipline, for call sites that build their content by writing
    # to an IO-like object (`f.puts`/`f.print`/...) — usually a large,
    # multi-hundred-line block — rather than handing over a finished
    # string. Writes to a SIBLING TEMP FILE first (a real `File` answers
    # every method those blocks already call on `f`, so a block body
    # needs no changes at all, only which object it's yielded), then
    # compares and either discards the temp file (content unchanged,
    # original's mtime untouched) or renames it into place (content
    # changed, one real write, same as before). Never touches the real
    # path unless the content actually differs.
    def block(path)
      record_touch(path)
      tmp = "#{path}.tmp-#{Process.pid}-#{rand(1_000_000)}"
      begin
        File.open(tmp, "w") { |f| yield f }
        if File.exist?(path) && FileUtils.compare_file(tmp, path)
          false
        else
          FileUtils.mv(tmp, path)
          true
        end
      ensure
        File.delete(tmp) if File.exist?(tmp)
      end
    end
  end
end

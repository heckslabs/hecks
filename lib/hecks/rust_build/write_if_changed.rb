# frozen_string_literal: true

require "fileutils"
require_relative "../rust_format"

module Hecks
  module RustBuild
    # Skips writes whose content is unchanged so file mtimes stay stable.
    # A rewrite alone forces Cargo to rebuild downstream crates.
    module WriteIfChanged
      module_function

      # Starts recording every path written or confirmed unchanged inside `dir`, against every open
      # ancestor directory too; `pop_and_prune` closes it and deletes the files never touched.
      def push_directory(dir)
        FileUtils.mkdir_p(dir)
        stack.push([File.expand_path(dir), Set.new])
      end

      # Matches by directory, not LIFO: nested directories can close out of order.
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

      # Writes `content` to `path` unless it already holds identical bytes.
      # Returns whether it wrote. `formatted` says the caller already ran `content` through rustfmt.
      # `atomic` writes a sibling temp file and renames it into place, so a process reading `path`
      # while others write the same bytes never sees a truncated or half-written file.
      def call(path, content, formatted: false, atomic: false)
        record_touch(path)
        content = RustFormat.call(content) if RustFormat.rust?(path) && !formatted
        # `.b` on both sides: String#== is encoding-aware, so UTF-8 vs ASCII-8BIT
        # content can compare unequal even when the bytes are identical.
        return false if File.exist?(path) && File.binread(path) == content.b

        atomic ? replace(path, content) : File.write(path, content)
        true
      end

      # Puts `content` at `path` by renaming a finished temp file over it. The temp file is hidden
      # (a leading dot), so a directory's `*` listing, which prunes what a run did not write, never
      # sees it, and it keeps the existing file's permissions.
      def replace(path, content)
        tmp = File.join(File.dirname(path), ".#{File.basename(path)}.tmp-#{Process.pid}")
        File.write(tmp, content)
        File.chmod(File.stat(path).mode & 0o7777, tmp) if File.exist?(path)
        File.rename(tmp, path)
      ensure
        FileUtils.rm_f(tmp)
      end
      private_class_method :replace

      # Fills `tmp` from the block, then lays it out with rustfmt when `path` is Rust source.
      def write_formatted(tmp, path, &)
        File.open(tmp, "w", &)
        File.write(tmp, RustFormat.call(File.read(tmp))) if RustFormat.rust?(path)
      end
      private_class_method :write_formatted

      # Like `call`, for callers that build content by writing to an IO. Yields a sibling
      # temp file, then renames it into place only if the bytes differ. Returns whether it wrote.
      def block(path, &)
        record_touch(path)
        tmp = "#{path}.tmp-#{Process.pid}-#{rand(1_000_000)}"
        begin
          write_formatted(tmp, path, &)
          changed = !(File.exist?(path) && FileUtils.compare_file(tmp, path))
          FileUtils.mv(tmp, path) if changed
          changed
        ensure
          FileUtils.rm_f(tmp)
        end
      end
    end
  end
end

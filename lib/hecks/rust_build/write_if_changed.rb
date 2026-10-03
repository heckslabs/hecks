# frozen_string_literal: true

require "fileutils"

module Hecks
  module RustBuild
    # Skips writes whose content is unchanged so file mtimes stay stable.
    # A rewrite alone forces Cargo to rebuild downstream crates.
    module WriteIfChanged
      module_function

      # Records every path written or confirmed unchanged inside the block, then deletes
      # files left in `dir` that were never touched (orphans of removed aggregates).
      # Every write is recorded against every open ancestor directory.
      # `push_directory`/`pop_and_prune` are the same operation split for non-adjacent writes.
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
      # Returns whether it wrote.
      def call(path, content)
        record_touch(path)
        # `.b` on both sides: String#== is encoding-aware, so UTF-8 vs ASCII-8BIT
        # content can compare unequal even when the bytes are identical.
        return false if File.exist?(path) && File.binread(path) == content.b

        File.write(path, content)
        true
      end

      # Like `call`, for callers that build content by writing to an IO. Yields a sibling
      # temp file, then renames it into place only if the bytes differ. Returns whether it wrote.
      def block(path, &)
        record_touch(path)
        tmp = "#{path}.tmp-#{Process.pid}-#{rand(1_000_000)}"
        begin
          File.open(tmp, "w", &)
          if File.exist?(path) && FileUtils.compare_file(tmp, path)
            false
          else
            FileUtils.mv(tmp, path)
            true
          end
        ensure
          FileUtils.rm_f(tmp)
        end
      end
    end
  end
end

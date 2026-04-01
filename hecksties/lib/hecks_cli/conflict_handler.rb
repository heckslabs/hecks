module Hecks
  class CLI < Thor
    # Hecks::CLI::ConflictHandler
    #
    # Mixin for CLI generators that write files. When a target file already
    # exists, shows a unified diff and offers interactive resolution. Supports
    # --force to overwrite without prompting. Uses system `diff -u` for real
    # unified diffs with proper insertion/deletion handling.
    #
    #   class MyCommand < Thor
    #     include ConflictHandler
    #
    #     def some_generator
    #       write_or_diff("app.rb", new_content)
    #     end
    #   end
    #
    module ConflictHandler
      # Writes a file, showing a diff if it already exists with different content.
      #
      # If the file does not exist, creates it (including parent directories).
      # If the file exists with identical content, reports it as up to date.
      # If the file exists with different content:
      # - With --force: overwrites without prompting
      # - With TTY: offers interactive resolution (overwrite/skip/diff/edit)
      # - Without TTY: prints instructions and skips
      #
      # @param path [String] the file path to write
      # @param new_content [String] the content to write
      # @return [Boolean] true if the file was written, false if skipped
      def write_or_diff(path, new_content)
        unless File.exist?(path)
          dir = File.dirname(path)
          FileUtils.mkdir_p(dir) unless dir == "."
          File.write(path, new_content)
          say "Created #{path}", :green
          return true
        end

        existing = File.read(path)
        if existing == new_content
          say "#{path} is already up to date", :green
          return false
        end

        force = options[:force] rescue false
        if force
          File.write(path, new_content)
          say "Overwrote #{path}", :green
          return true
        end

        say "#{path} differs:", :yellow
        show_diff(existing, new_content, path)

        if $stdin.tty?
          resolve_interactively(path, new_content)
        else
          say "Run with --force to overwrite, or apply manually.", :yellow
          false
        end
      end

      private

      # Displays a colored unified diff between old and new content.
      #
      # Uses system `diff -u` with temp files, then replaces temp file paths
      # with meaningful labels. Colors: red for deletions, green for additions,
      # cyan for hunk headers.
      #
      # @param old_content [String] the existing file content
      # @param new_content [String] the proposed new content
      # @param path [String] the file path (used for labels)
      # @return [void]
      def show_diff(old_content, new_content, path)
        require "tempfile"
        old_file = Tempfile.new(["old", File.extname(path)])
        new_file = Tempfile.new(["new", File.extname(path)])
        old_file.write(old_content); old_file.close
        new_file.write(new_content); new_file.close

        diff = `diff -u "#{old_file.path}" "#{new_file.path}" 2>/dev/null`
        # Replace temp paths with meaningful labels
        diff = diff.sub(/^---.*$/, "--- #{path} (existing)")
                   .sub(/^\+\+\+.*$/, "+++ #{path} (generated)")
        diff.each_line do |line|
          case line[0]
          when "-" then say line.chomp, :red
          when "+" then say line.chomp, :green
          when "@" then say line.chomp, :cyan
          else say line.chomp
          end
        end
      ensure
        old_file&.unlink
        new_file&.unlink
      end

      # Offers interactive resolution for a file conflict.
      #
      # Loops until the user chooses an action:
      # - y/yes: overwrite the file
      # - n/no/enter: skip the file
      # - d/diff: show the diff again
      # - e/edit: open the file in $EDITOR
      #
      # @param path [String] the conflicting file path
      # @param new_content [String] the proposed new content
      # @return [Boolean] true if the file was written, false if skipped
      def resolve_interactively(path, new_content)
        loop do
          answer = ask("  [y]es overwrite / [n]o skip / [d]iff again / [e]dit in $EDITOR: ")
          case answer.strip.downcase
          when "y", "yes"
            File.write(path, new_content)
            say "Updated #{path}", :green
            return true
          when "n", "no", ""
            say "Skipped #{path}", :yellow
            return false
          when "d", "diff"
            show_diff(File.read(path), new_content, path)
          when "e", "edit"
            open_in_editor(path, new_content)
            return true
          end
        end
      end

      # Opens a file in the user's editor with the generated version as reference.
      #
      # Writes the generated content to a temp file so the user can reference it,
      # then opens the existing file in $EDITOR (defaults to vim).
      #
      # @param path [String] the file to edit
      # @param new_content [String] the generated content (saved as temp reference)
      # @return [void]
      def open_in_editor(path, new_content)
        # Write generated version to a temp file for reference
        require "tempfile"
        ref = Tempfile.new(["generated", File.extname(path)])
        ref.write(new_content); ref.close
        say "Generated version saved to: #{ref.path}", :cyan
        editor = ENV["EDITOR"] || "vim"
        system("#{editor} #{path}")
        say "Kept your edits in #{path}", :green
      ensure
        ref&.unlink
      end
    end
  end
end

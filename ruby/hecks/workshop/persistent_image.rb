# Hecks::Workshop::PersistentImage
#
# Mixin that adds file-based save/restore for SessionImage objects.
# Serializes images as plain Ruby files with a metadata header comment
# and the DSL source body. The format is human-readable and can be
# eval'd directly if needed.
#
# Files are stored in a configurable directory (default: .hecks/images/).
# Each file is named after the domain with a .heckimage extension.
#
#   workshop.save_image                     # saves to .hecks/images/pizzas.heckimage
#   workshop.save_image("checkpoint")       # saves to .hecks/images/checkpoint.heckimage
#   workshop.restore_image                  # restores from .hecks/images/pizzas.heckimage
#   workshop.restore_image("checkpoint")    # restores named image
#   SessionImage.list_images                # list all saved images
#
module Hecks
  class Workshop
    module PersistentImage
      IMAGE_DIR = ".hecks/images"
      IMAGE_EXT = ".heckimage"

      # Save the current workshop state to a file.
      #
      # @param label [String, nil] optional name for the image (defaults to domain name)
      # @param dir [String] directory to save into
      # @return [String] the path written
      def save_image(label = nil, dir: IMAGE_DIR)
        image = SessionImage.capture(self)
        path = image_path(label, dir: dir)
        FileUtils.mkdir_p(File.dirname(path))
        write_image_file(path, image)
        puts "Saved image: #{path}"
        path
      end

      # Restore workshop state from a saved image file.
      #
      # @param label [String, nil] name of the image to restore (defaults to domain name)
      # @param dir [String] directory to search
      # @return [Hecks::Workshop] self
      def restore_image(label = nil, dir: IMAGE_DIR)
        path = image_path(label, dir: dir)

        unless File.exist?(path)
          puts "No image found at #{path}"
          return self
        end

        image = read_image_file(path)
        image.restore_into(self)
        puts "Restored image: #{path} (captured #{image.captured_at})"
        self
      end

      # List all saved images in the given directory.
      #
      # @param dir [String] directory to scan
      # @return [Array<String>] image file paths
      def list_images(dir: IMAGE_DIR)
        return [] unless Dir.exist?(dir)

        Dir.glob(File.join(dir, "*#{IMAGE_EXT}")).sort
      end

      private

      # Build the file path for an image.
      #
      # @param label [String, nil] optional label
      # @param dir [String] base directory
      # @return [String] full path
      def image_path(label, dir:)
        slug = (label || @name).downcase.gsub(/[^a-z0-9_]/, "_")
        File.join(dir, "#{slug}#{IMAGE_EXT}")
      end

      # Write a SessionImage to a file with metadata header.
      #
      # @param path [String] file path
      # @param image [SessionImage] the image to write
      def write_image_file(path, image)
        content = []
        content << "# Hecks Session Image"
        content << "# Domain: #{image.domain_name}"
        content << "# Captured: #{image.captured_at.iso8601}"
        content << "# Custom verbs: #{image.custom_verbs.join(', ')}"
        content << ""
        content << image.dsl_source
        File.write(path, content.join("\n"))
      end

      # Read a SessionImage from a file, parsing the metadata header.
      #
      # @param path [String] file path
      # @return [SessionImage] the restored image
      def read_image_file(path)
        lines = File.readlines(path, chomp: true)
        domain_name = nil
        captured_at = nil
        custom_verbs = []
        dsl_start = 0

        lines.each_with_index do |line, i|
          case line
          when /^# Domain:\s*(.+)/
            domain_name = Regexp.last_match(1).strip
          when /^# Captured:\s*(.+)/
            captured_at = Time.parse(Regexp.last_match(1).strip)
          when /^# Custom verbs:\s*(.*)/
            verbs = Regexp.last_match(1).strip
            custom_verbs = verbs.empty? ? [] : verbs.split(",").map(&:strip)
          when /^#/
            next
          else
            dsl_start = i
            break
          end
        end

        dsl_source = lines[dsl_start..].join("\n") + "\n"

        SessionImage.new(
          domain_name:  domain_name,
          dsl_source:   dsl_source,
          custom_verbs: custom_verbs,
          captured_at:  captured_at || File.mtime(path)
        )
      end
    end
  end
end

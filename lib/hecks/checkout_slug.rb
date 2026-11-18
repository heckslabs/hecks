# frozen_string_literal: true

require "digest/sha2"

module Hecks
  # The name a hecks checkout's own directory takes inside a shared cache (a Cargo target slot, a
  # compiled-Ruby cache), and the file in that directory that records the checkout it belongs to.
  #
  # The name is the checkout's base name and a digest of its path, so two checkouts never share
  # one. The owner file lets a prune tell a directory whose checkout is gone from one whose
  # checkout git lists under another spelling. It loads only `digest/sha2`, so a launcher's boot
  # can ask it before anything else is loaded.
  module CheckoutSlug
    # File in a checkout's cache directory naming the checkout it belongs to.
    OWNER = ".owner"

    module_function

    # @param root [String] a hecks checkout
    # @return [String] the checkout's name and the first eight hex digits of its path's digest
    def slug(root)
      path = File.expand_path(root)
      "#{File.basename(path)}-#{Digest::SHA256.hexdigest(path)[0, 8]}"
    end

    # The names a checkout's directory may carry: its path as given and as the file system spells
    # it, which differ where a path crosses a symlink (`/var` and `/private/var`).
    #
    # @param root [String] a hecks checkout
    # @return [Array<String>] the distinct names
    def slugs(root)
      [slug(root), slug(File.realpath(root))].uniq
    rescue SystemCallError
      [slug(root)]
    end

    # Makes the directory and records +root+ as its owner, before anything writes to it; a
    # directory that cannot be written to is left unrecorded.
    #
    # @param dir [String] a checkout's cache directory
    # @param root [String] the checkout it belongs to
    # @return [String] +dir+
    def claim(dir, root)
      file = File.join(dir, OWNER)
      owner = File.realpath(root)
      write(dir, file, owner) unless File.file?(file) && File.read(file) == owner
      dir
    rescue SystemCallError
      dir
    end

    # @param dir [String] a checkout's cache directory
    # @return [String, nil] the checkout the directory records as its owner
    def owner_of(dir)
      file = File.join(dir, OWNER)
      File.file?(file) ? File.read(file).strip : nil
    rescue SystemCallError
      nil
    end

    # @return [void]
    def write(dir, file, owner)
      require "fileutils"
      FileUtils.mkdir_p(dir)
      File.write(file, owner)
    end
    private_class_method :write
  end
end

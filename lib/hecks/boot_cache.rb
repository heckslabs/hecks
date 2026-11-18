# frozen_string_literal: true

require_relative "cache_dir"
require_relative "checkout_slug"

module Hecks
  # The compiled-Ruby cache (Bootsnap) a hecks boot keeps between boots, one per checkout.
  #
  # Bootsnap keeps an entry for every file path it compiled, named by a digest of the path, so one
  # cache shared by every worktree kept the entries of each worktree that ever booted. Each
  # checkout's cache is a directory of its own under the hecks cache's `bootsnap`, named by
  # {CheckoutSlug} and claimed with an owner file, so a removed checkout's entries go with one
  # directory ({BootCache::Sweep}).
  module BootCache
    # The cache-directory name every checkout's directory lives under.
    NAME = "bootsnap"

    module_function

    # Sets Bootsnap up on the checkout's own directory, when the cache root lasts between
    # processes; a boot without the gem, or on the temp-directory fallback, runs without it.
    #
    # @param root [String] the hecks checkout this boot runs from
    # @return [void]
    def setup(root)
      require "bootsnap"
      return unless CacheDir.stable?

      Bootsnap.setup(cache_dir: CheckoutSlug.claim(dir(root), root), development_mode: true,
                     load_path_cache: true, compile_cache_iseq: true, compile_cache_yaml: false)
    rescue ScriptError, StandardError
      nil
    end

    # @return [String] the directory every checkout's compiled-Ruby cache lives in
    def base = CacheDir.path(NAME)

    # @param root [String] a hecks checkout
    # @return [String] the checkout's own compiled-Ruby cache directory; nothing is made
    def dir(root) = File.join(base, CheckoutSlug.slug(root))

    # @param root [String] a hecks checkout
    # @return [Array<String>] the directories the checkout's cache may be in, under each spelling
    #   of its path
    def dirs_of(root) = CheckoutSlug.slugs(root).map { |name| File.join(base, name) }
  end
end

require_relative "../runtime/errors"

module Hecks
  # Dispatch, query and introspection over one booted domain; this file holds the one piece a
  # stdio server needs before the framework loads: the root a domain path must stay under.
  module Storehouse
    # The root every domain path resolves under; HECKS_STOREHOUSE_ROOT widens it.
    # Hecks.boot Kernel.loads Ruby files here, so an unconfined path is
    # arbitrary code execution, not just a wrong-directory mistake.
    BOOT_ROOT = File.expand_path(ENV["HECKS_STOREHOUSE_ROOT"] || File.expand_path("../../..", __dir__))

    # The check that keeps a domain path under `BOOT_ROOT`. It lives apart from the rest of
    # `Storehouse` so a stdio server can confine a path without loading the framework.
    module Confinement
      # Refuses a path outside BOOT_ROOT rather than silently clamping it — a
      # stray relative path and a deliberate escape both deserve a clear refusal.
      #
      # @param path [String] the path asked for, relative to `BOOT_ROOT` or absolute
      # @param label [String] what the path is for, named in the refusal
      # @return [String] the absolute path
      # @raise [Runtime::TypeMismatch] when the path resolves outside `BOOT_ROOT`
      def confine!(path, label)
        resolved = File.expand_path(path.to_s, BOOT_ROOT)
        return resolved if resolved == BOOT_ROOT || resolved.start_with?("#{BOOT_ROOT}#{File::SEPARATOR}")

        raise Runtime::TypeMismatch,
              "#{label}: #{path.inspect} resolves outside #{BOOT_ROOT} — this bus only boots domains under its " \
              "own root (HECKS_STOREHOUSE_ROOT to widen it)"
      end
    end

    extend Confinement
  end
end

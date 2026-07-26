# Loading — the port's execution : the one resolution that cannot be a lookup.
#
# Every other port resolves by asking the registry which adapter declared it.
# This one cannot, and the reason is not an oversight : resolving a port means
# READING THE FILE that declares it, and reading files is precisely what this
# port does. The lookup would have to load the thing that makes loading
# possible.
#
# So `bootstrap` names that circularity instead of hiding it. It is the single
# hardcoded edge in the system, it is one line, and it is the ONLY place in the
# library where an adapter is reached for by constant rather than resolved
# through its port.
#
# What this buys — and it is worth being honest that it is not nothing — is that
# boot's IO stops being a scatter of unexamined `Dir[]` and `File.directory?`
# calls spread through a loader, and becomes ONE named edge with a declared
# contract. The circularity was always there. It just had no name, so nothing
# could be said about it and nothing else could ever take its place.
#
# A second loading adapter — a gem shipping declarations as constants, a
# manifest, a database of domains — is additive against the port. Only the first
# few milliseconds of boot are pinned to Folder ; everything after resolves
# normally.
#
#   Ports::Loading.bootstrap  # => Adapters::Folder
module Hecksagain
  module Ports
    module Loading
      NAME = "loading"

      module_function

      # The single hardcoded edge. See above for why it cannot be a lookup.
      def bootstrap = Adapters::Folder.new
    end
  end
end

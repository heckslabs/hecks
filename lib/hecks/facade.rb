# The deprecated alias shim: `Hecks::Facade` is now `Hecks::Doors` and `Doors::Surface` is
# `Doors::RubyDoor`. Both old constants still resolve and warn; they are removed in
# `Hecks::Doors::REMOVAL`.
require_relative "doors"

# The root namespace; this file holds only the deprecated aliases.
module Hecks
  # Resolves the constants that now live in `Doors` under their old names, warning on each use.
  #
  # Extended onto `Hecks` and `Hecks::Doors`, ahead of `Module#const_missing`.
  module DoorsAliases
    # Old constant name mapped to the new one, per namespace that carried it.
    RENAMED = { Hecks => { Facade: "Hecks::Doors" }, Hecks::Doors => { Surface: "Hecks::Doors::RubyDoor" } }.freeze

    # Answers a renamed constant with its replacement and a warning; anything else
    # goes to the next `const_missing`.
    #
    # @param name [Symbol] the missing constant
    # @return [Module] the replacement module
    def const_missing(name)
      target = RENAMED.fetch(self, {})[name]
      return super unless target

      warn "[hecks] #{self}::#{name} is deprecated and is removed in #{Hecks::Doors::REMOVAL}; use #{target}"
      Object.const_get(target)
    end
  end

  extend DoorsAliases
  Doors.extend(DoorsAliases)
end

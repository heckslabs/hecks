# frozen_string_literal: true

require "tmpdir"

# Every adapter stand-in a spec puts in place answers the `Beating` port with a real place kept
# in a temporary directory, so a spec that stands in its own adapters still has its beats taken.
# A spec of the place itself names its own directory with `BeatPlaceDefault.dir=`.
module BeatPlaceDefault
  class << self
    attr_writer :dir

    # @return [String] the directory the place is kept in: one per process unless a spec names it
    def dir = @dir ||= Dir.mktmpdir("beat-place")

    # @return [Hecks::Adapters::Beating] the place, over the current directory
    def place
      require "hecks/hecks/adapters/beating"
      Hecks::Adapters::Beating.new(settings: { dir: dir })
    end
  end

  # Wraps the stand-in so that the `Beating` port is answered by the place.
  #
  # @param stand_in [#call, nil] answers `(port_name, asked)`
  def standing_in(stand_in, &)
    return super unless stand_in

    super(->(port, asked) { port.to_s == "Beating" ? BeatPlaceDefault.place : stand_in.call(port, asked) }, &)
  end
end

Hecks::Runtime::AdapterLookup.singleton_class.prepend(BeatPlaceDefault)

# The real `Beating` adapter a booted domain builds keeps its place in the process's temporary
# directory too, so a beat in a spec is never declined by a beat running on the machine or in
# another spec process. A spec that names a `dir:` keeps it.
module BeatPlaceOwnDirectory
  def new(settings: {}, **rest) = super(settings: { dir: BeatPlaceDefault.dir }.merge(settings), **rest)
end

require "hecks/hecks/adapters/beating"
Hecks::Adapters::Beating.singleton_class.prepend(BeatPlaceOwnDirectory)

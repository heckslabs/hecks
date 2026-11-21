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

    # @return [Hecks::Adapters::Beating] the place, over the current directory and the asking
    #   registry, so a beat taken in a spec is measured as a real one is
    def place
      require "hecks/hecks/adapters/beating"
      Hecks::Adapters::Beating.new(registry: Hecks::Runtime::Asking.registry, settings: { dir: dir })
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

# The place a beat takes is kept for the life of its process, so a beat in one example would leave
# it held for the next example of the process, and a spec of the place itself would find it taken.
# Every example starts with no place held and the lock closed.
RSpec.configure do |config|
  config.before do
    Hecks::Adapters::Beating.held&.close
    Hecks::Adapters::Beating.held = nil
  end
end

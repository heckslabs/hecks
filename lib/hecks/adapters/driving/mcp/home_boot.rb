require "delegate"
require_relative "../../../naming"

module Hecks
  module Adapters
    module Driving
      module Mcp
        # What a restricted server answers a read of an attached bluebook from. A directory beside
        # the home domain (`lib/hecks/hecks`) whose bluebook the home hecksagon attaches does not
        # keep its rows when it boots standing alone, so a read naming it is answered from the home
        # domain, booted as the launcher boots it for a question: read-only, with no environment,
        # so the overlays that name the live stores apply. The home boot is kept until a file of
        # the home directory or of an attached directory changes. A read of the home directory
        # itself, or of a directory the home does not attach, is answered from the door's own boot,
        # which is Memory under the door's environment; so `state` of one aggregate can answer
        # differently in the home directory than in an attached one. A dispatch never uses this
        # boot.
        module HomeBoot
          # The home runtime, answering as one attached bluebook: `first_bluebook` is that bluebook,
          # so every read of the storehouse speaks to it.
          class Scoped < SimpleDelegator
            # @param runtime [Runtime::Dispatcher] the home runtime
            # @param name [String] the attached bluebook's name
            def initialize(runtime, name)
              super(runtime)
              @name = name
            end

            # @return [Bluebook::Declaration] the attached bluebook
            def first_bluebook = bluebook(@name)
          end

          # The attached bluebook a directory is, as the home domain attaches it.
          #
          # @param path [String] the confined directory a read names
          # @return [Array(String, String), nil] the home directory and the bluebook name, or nil
          def attached_read(path)
            home = File.join(File.dirname(path), "hecks")
            return if path == home || !File.directory?(home)

            name = home_state(home)[:names].find { |each| Naming.snake(each) == File.basename(path) }
            [home, name] if name
          end

          # The runtime that answers a read of `path`, and the one that answers every other call.
          #
          # @param path [String] the confined directory a read names
          # @return [Runtime::Dispatcher, nil] the home runtime as the attached bluebook, or nil
          def home_runtime(path)
            home, name = attached_read(path)
            return unless name

            Scoped.new(home_state(home)[:runtime], name)
          end

          private

          def home_state(home)
            kept = (@home_boots ||= {})[home]
            return kept if kept && kept[:fingerprint] == home_fingerprint(home, kept[:names])

            described = Hecks.describe(home, environment: nil)
            names = attached_names(described)
            runtime = Hecks.boot_described(described, install_driving: false, read_only: true)
            @home_boots[home] = { names: names, runtime: runtime, fingerprint: home_fingerprint(home, names) }
          end

          def attached_names(described)
            home = described.first_bluebook
            Array(described.hecksagon(home.name)&.member_bluebooks)
          end

          def home_fingerprint(home, names)
            parts = [home, *names.map { |name| File.join(File.dirname(home), Naming.snake(name)) }]
            prints = parts.select { |dir| File.directory?(dir) }.map { |dir| Storehouse.fingerprint(dir) }
            Digest::SHA256.hexdigest(prints.join)
          end
        end
      end
    end
  end
end

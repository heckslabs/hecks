module Hecks
  module Adapters
    module Driving
      module Resident
        # Records which environment variables the code reads while it loads. A resident loads once
        # and a constant that was set from a variable keeps that value for every line, so a line
        # made with another value of one of them must not be served from it.
        #
        # Only the variables that can shape the Hecks code are kept (`HECKS_*`, `CARGO_*`, `PG*`);
        # a variable read when a line runs, such as `HECKS_CALLER`, is not read while loading and
        # never lands here.
        module EnvTrace
          # The names worth keeping.
          KEPT = /\A(HECKS_|CARGO_|PG)/

          @names = {}
          @on = false

          class << self
            # @return [Array<String>] the variables read while tracing
            def names = @names.keys

            # Notes a read, when tracing is on.
            def record(name) = (@names[name.to_s] = true if @on && name.to_s.match?(KEPT))

            # Runs the block with every read of `ENV` noted.
            def tracing
              install
              @on = true
              yield
            ensure
              @on = false
            end

            private

            def install = (ENV.singleton_class.prepend(Reads) unless ENV.singleton_class.include?(Reads))
          end

          # The reads of `ENV` that name one variable.
          module Reads
            %i[[] fetch key? include? has_key?].each do |reader|
              define_method(reader) do |name, *rest, &block|
                EnvTrace.record(name)
                super(name, *rest, &block)
              end
            end
          end
        end
      end
    end
  end
end

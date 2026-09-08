require_relative "../../runtime/registry"

module Hecks
  module Ports
    module Persistence
      # THE OTHER SHAPE AN ADAPTER CAN BE. `AppendOnly` names one shape
      # already — something that stores bytes, locally (Postgres, SQLite,
      # Heki) or over the network (D1), doesn't matter, the point is it
      # does real local interpretation and has real entries to replay.
      # This names the second, different shape: not "storage reached
      # remotely," but the real INTERPRETER itself living behind a call
      # boundary — `append`/`project` don't do partial local work and
      # then fail, they raise unconditionally, because there is no local
      # write-ahead log to have; `entries` is always `[]` for the same
      # reason (`AppendOnly#recover!` replaying zero entries here is a
      # correct no-op, not a lie).
      #
      # `Adapters::Lambda` is the first adapter to `include` this, not
      # the only one meant to — any future adapter for some other
      # remote-runtime target (a different compute platform, a gRPC
      # stub, whatever) gets this shape for free by including one module
      # instead of re-deriving the same raise-on-write/always-empty-
      # entries boilerplate from scratch. And because it's a real,
      # checkable module rather than an adapter's own ad hoc
      # implementation, a caller can ask "is this adapter a remote-
      # runtime delegate?" as a genuine capability check
      # (`registry.adapter_class(name) <= RemoteRuntime`,
      # `Runtime::RemoteDispatcher`'s own use) instead of comparing
      # adapter names by string.
      module RemoteRuntime
        def append(*)
          raise Runtime::WiringError,
                "#{self.class.name} is a remote-runtime delegate — dispatch through " \
                "Runtime::RemoteDispatcher instead of writing through the repository directly"
        end
        alias project append

        def entries = []
      end
    end
  end
end

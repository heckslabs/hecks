require "fileutils"
require "tmpdir"
require "securerandom"

module Hecks
  module Fuzzing
    # A FRESH, IN-PROCESS ADAPTER FOR EVERY EPHEMERAL BOOT.
    #
    # Fuzzing/replay copies a domain to a tmpdir and boots from there
    # specifically to get zero-history state — `rm_rf`ing the copy's own
    # `data/` achieves that for a file-based adapter (Memory,
    # SqlitePersistence, Heki), because copying the DIRECTORY copies the
    # store. It achieves nothing for an adapter that lives outside the
    # copied directory entirely — Postgres, named by a fixed connection
    # string in `.world` (examples/pizzas/bluebook/pizzas.world, for
    # instance). Copying the directory does not copy or isolate the
    # DATABASE, so a "fresh" boot against a Postgres-bound domain would
    # still see every record any other run, ever, wrote to it.
    #
    # So every `.hecksagon` in the copy gets its persistence binding
    # rewritten to Memory before booting, and any `projected_by` bind
    # dropped outright (optional — `Registry#read_repository` already
    # falls back to the authoritative repository when none exists). The
    # domain's own rules and shape are untouched ; only WHICH adapter this
    # one ephemeral copy answers through changes. What the domain is
    # bound to for real deployment is never touched — only this tmp copy.
    #
    # `adapter:` (PRD 02) — Memory is the default and the only mode every
    # existing caller still gets with no change. `:sqlite` rebinds to the
    # REAL SQLite adapter instead of the in-memory one, for exactly the
    # same reason PRD 02 exists: 15 declared properties (properties.rb)
    # and every fuzz/replay run has only ever been checked against
    # Memory's own hand-written repository, never against a real,
    # persisted, SQL-backed one — and `spec/adapters/query_agreement_spec
    # .rb` already found 4 shipped query bugs from exactly that
    # comparison, on a fixed corpus far smaller than what the fuzzer
    # generates. `:sqlite` rewrites to `"SqlitePersistence"` — the name
    # `lib/hecks/adapters/driven/sqlite.adapter` actually registers under
    # (`Sqlite` is the class; `SqlitePersistence` is a thin subclass
    # that's the one real port binding names) — and needs no `.world`
    # settings at all, the same reason Memory needs none:
    # `Sqlite#resolve_path` already defaults an
    # unbound `database` setting to `"data/<table>.db"` relative to
    # `root:`, which `Hecks.boot(copy)` passes as this ephemeral copy's
    # own directory — a fresh, empty `data/` per run, exactly like
    # Memory's own zero-history guarantee, just backed by a real SQLite
    # file instead of a Hash. Postgres/PostgresEra are deliberately NOT
    # added here: a real Postgres run needs a live server and shared
    # connection settings this in-process, no-adapter-config path has no
    # place to source safely — that stays `io: true`-gated, direct-adapter
    # coverage (`spec/adapters/driven/postgres_*_spec.rb`), not this.
    module IsolatedBoot
      module_function

      # PRD 02 (docs/future-features.md) — `adapter:` picks WHICH real
      # persistence this one ephemeral boot answers through, not just
      # Memory. `:memory` is the original, zero-config behavior (every
      # other caller in this codebase that doesn't pass `adapter:` gets
      # exactly what it always got). `:sqlite` is nearly as cheap —
      # `Adapters::Sqlite#resolve_path` already defaults to
      # `data/<table>.db` under the copy's own root with no settings at
      # all, the same "needs nothing declared" property Memory has, so a
      # real on-disk B-tree gets exercised for free. `:postgres` is the
      # expensive one — a real server, a real round trip per dispatch —
      # so `bin/fuzz --adapter postgres` is meant to run with smaller
      # seed/step counts than the Memory default, not as a like-for-like
      # swap; see that flag's own comment.
      def call(domain_path, adapter: :memory)
        Dir.mktmpdir("hecks-fuzz") do |tmp|
          copy = File.join(tmp, File.basename(domain_path))
          copy_dereferencing(domain_path, copy)
          FileUtils.rm_rf(File.join(copy, "data"))
          case adapter
          when :memory   then rebind_to_memory!(copy)
          when :sqlite   then rebind_to_sqlite!(copy)
          when :postgres then rebind_to_postgres!(copy)
          else raise ArgumentError, "unknown fuzz adapter #{adapter.inspect} — :memory, :sqlite, or :postgres"
          end
          yield copy
        end
      end

      # SYMLINKS ARE FOLLOWED, NOT COPIED. `FileUtils.cp_r` reproduces a
      # symlink AS a symlink, and a RELATIVE one then points at nothing
      # from a tmpdir — `lib/hecks/framework/bluebook/compliance
      # .bluebook` is exactly that, a link to
      # `examples/compliance/bluebook/compliance.bluebook`, so the whole
      # framework domain failed to boot here with a LoadError naming a
      # path under /var/folders that had never existed. Nothing about the
      # domain was wrong; the copy was.
      #
      # `FileUtils.cp` follows a symlink and copies its CONTENT, which is
      # what an isolated boot wants: the copy has to stand alone, since
      # rebind! rewrites files in it and must not reach back through a
      # link into the real tree.
      def copy_dereferencing(source, destination)
        FileUtils.mkdir_p(destination)
        Dir.glob(File.join(source, "**", "*"), File::FNM_DOTMATCH).each do |path|
          next if [".", ".."].include?(File.basename(path))

          target = File.join(destination, path.delete_prefix("#{source}/"))
          if File.directory?(path)
            FileUtils.mkdir_p(target)
          else
            FileUtils.mkdir_p(File.dirname(target))
            FileUtils.cp(path, target)
          end
        end
      end

      def rebind_to_memory!(copy)
        rewrite_bindings!(copy, "Memory")

        # THE SETTINGS, NOT JUST THE BIND — `WorldBuilder#method_missing`
        # stores a settings block under BOTH "verb:adapter" and the bare
        # "verb" (world_builder.rb:32-33), so a bind rewritten to Memory
        # still falls back to whatever adapter's settings were declared
        # bare — Postgres's `database:`, which Memory does not take and
        # WiringError refuses on sight. Both Memory and Sqlite need no
        # settings at all (`Sqlite#resolve_path` defaults `database` to
        # `data/<table>.db` under `root:` when unset — the same
        # zero-config default Memory gets from having no `.world` at
        # all), so the simplest correct fix for either target is
        # dropping `.world` from the copy entirely.
        Dir.glob(File.join(copy, "**", "*.world")).each { |path| File.delete(path) }
      end

      # SAME DANCE AS MEMORY, ONE ADAPTER OVER — `Adapters::Sqlite#
      # resolve_path` (adapters/driven/sqlite.rb) defaults to
      # `data/<table>.db` under the boot's own root when no `database`
      # setting is declared, which `data/` already being cleared makes a
      # fresh on-disk store with zero configuration, the same "no .world
      # needed" property Memory has. `data/` itself is left for Sqlite to
      # recreate on first write, same as it always was for Memory/Heki —
      # nothing here creates it up front.
      def rebind_to_sqlite!(copy)
        rewrite_bindings!(copy, "SqlitePersistence")
        Dir.glob(File.join(copy, "**", "*.world")).each { |path| File.delete(path) }
      end

      # THE EXPENSIVE ONE — Postgres has no zero-config default the way
      # Sqlite/Memory do (`Adapters::Postgres.connect_for` refuses outright
      # with no `database` setting), so dropping `.world` the way the
      # other two do would just move the WiringError from "wrong adapter"
      # to "no adapter." Every domain name this copy declares gets a
      # FRESH `.world` written for it instead — not a rewrite of whatever
      # was there, a replacement, same reasoning `rewrite_bindings!`
      # already applies to `.hecksagon`: this ephemeral boot owns every
      # binding decision, nothing about a real deployment's own settings
      # is relevant or safe to half-preserve here.
      #
      # ONE SHARED SCHEMA, DROPPED AND RECREATED BEFORE EVERY BOOT — not a
      # fresh randomly-named one per call. `bin/fuzz` drives every
      # ephemeral boot sequentially (one `IsolatedBoot.call` fully exits
      # before the next begins — see that file's own single-threaded
      # `while` loop), so nothing is ever concurrent here ; a fresh name
      # every time would just leak schemas in `FUZZ_POSTGRES_DATABASE`
      # forever with nothing to ever drop them. If a caller ever DOES
      # start running fuzz adapters concurrently, this needs to move to a
      # process-unique schema name (`SecureRandom.hex` is already
      # `require`d here for exactly that day) — flagged, not solved,
      # since nothing today calls this from more than one thread.
      FUZZ_POSTGRES_DATABASE = "hecks_fuzz".freeze
      FUZZ_POSTGRES_SCHEMA   = "hecks_fuzz".freeze

      def rebind_to_postgres!(copy)
        require "pg"
        rewrite_bindings!(copy, "Postgres")
        ensure_fuzz_schema!

        # ONE `.world` PER DIRECTORY A `.hecksagon` ACTUALLY LIVES IN, not
        # one at `copy`'s own root — `Folder#load_domain` resolves a
        # SINGLE `bluebook_directory` and globs `*.world` there, non-
        # recursively (`Folder#load_each`); a domain can hold several
        # `Hecks.hecksagon "<Name>" do ... end` SIBLING blocks in that one
        # file (banking.hecksagon declares "Banking", "Governance", and
        # "Identity" together), so every name found in one `.hecksagon`
        # file gets bundled into one `.world` written beside it, not
        # scattered by name.
        Dir.glob(File.join(copy, "**", "*.hecksagon")).each do |hecksagon_path|
          names = File.read(hecksagon_path).scan(/Hecks\.hecksagon\s+"([^"]+)"/).flatten.uniq
          next if names.empty?

          world_path = File.join(File.dirname(hecksagon_path), "hecks_fuzz_postgres.world")
          File.write(world_path, names.map do |name|
            <<~WORLD
              Hecks.world "#{name}" do
                persisted_by("Postgres") do
                  database "#{FUZZ_POSTGRES_DATABASE}"
                  schema "#{FUZZ_POSTGRES_SCHEMA}"
                end
              end
            WORLD
          end.join("\n"))
        end

        # Any PRE-EXISTING `.world` this copy shipped with (a real
        # deployment's own connection string) is now redundant with — and
        # would conflict with, `Registry#add_world`'s own header on
        # loading the same domain name twice — the fresh one just
        # written above, so it goes the same way `rebind_to_memory!`
        # already sends every `.world` in a Memory-mode boot.
        Dir.glob(File.join(copy, "**", "*.world")).each do |path|
          File.delete(path) unless File.basename(path) == "hecks_fuzz_postgres.world"
        end
      end

      # ADMIN CONNECTION LIVES OUTSIDE THE TMP COPY ENTIRELY — same as
      # every other real-Postgres spec in this repo (`support/
      # postgres_probe.rb`'s own header). Database created once per
      # process and remembered (`@fuzz_database_ready` on this module's
      # own singleton, the same memoization shape `PostgresProbe
      # .available?` already uses) ; the schema inside it is dropped and
      # recreated on EVERY call, which is what actually isolates one
      # ephemeral boot's data from the next.
      def ensure_fuzz_schema!
        # `Adapters::Postgres#initialize` opens ONE real `PG::Connection`
        # PER AGGREGATE and never explicitly closes it — fine for a
        # process that boots once and runs, exactly what every other
        # caller of this adapter is. A fuzz run boots dozens to hundreds
        # of EPHEMERAL times in one process (every seed does at least a
        # generate + a replay, `replay_is_deterministic` doubles that,
        # shrinking multiplies it further), and `PG::Connection` only
        # actually closes its socket when Ruby's GC finalizes the
        # (by-then-unreferenced) object — which, under a tight loop like
        # this, does not reliably keep pace with how fast new
        # connections open. Discovered live: `bin/fuzz --adapter
        # postgres` against `examples/banking` hit a real local
        # Postgres's own `max_connections` after roughly a dozen
        # ephemeral boots, `PG::ConnectionBad: ... "too many clients
        # already"`. A `GC.start` here — right before the next ephemeral
        # boot's connections open, not on some timer — reclaims every
        # connection the PREVIOUS boot's now-unreferenced adapters held,
        # keeping the live count bounded regardless of run length. This
        # is a real constraint on running Postgres in a loop, not
        # something to route around by connecting less carefully.
        GC.start

        unless @fuzz_database_ready
          admin = PG.connect(dbname: "postgres")
          exists = admin.exec_params(
            "SELECT 1 FROM pg_database WHERE datname = $1", [FUZZ_POSTGRES_DATABASE]
          ).ntuples.positive?
          admin.exec(%(CREATE DATABASE "#{FUZZ_POSTGRES_DATABASE}")) unless exists
          admin.close
          @fuzz_database_ready = true
        end

        db = PG.connect(dbname: FUZZ_POSTGRES_DATABASE)
        # QUIET ON PURPOSE — same as `Adapters::Postgres.connect_for`'s
        # own `SET client_min_messages`: a `DROP SCHEMA ... CASCADE` that
        # actually has something to drop (every boot after the first)
        # NOTICEs once per dropped object, which is the ordinary case
        # here, not news, and would otherwise bury `bin/fuzz`'s own
        # output under a wall of "drop cascades to table ..." on every
        # single ephemeral boot.
        db.exec("SET client_min_messages = warning")
        quoted = db.quote_ident(FUZZ_POSTGRES_SCHEMA)
        db.exec("DROP SCHEMA IF EXISTS #{quoted} CASCADE")
        db.exec("CREATE SCHEMA #{quoted}")
        db.close
      end

      # THE SHARED REWRITE — factored out of `rebind_to_memory!` when
      # Sqlite/Postgres modes needed the identical `.hecksagon` surgery
      # with only the target adapter name differing. `persisted_by`/
      # `projected_by` can be spelled two ways: aggregate-scoped
      # (`Banking::Customer.persisted_by("Heki")`, always parenthesised)
      # and, since §0's domain-level default binds, a bare call at the
      # hecksagon's own root (`persisted_by "Heki"`, no parens, no
      # receiver). Both must be caught here or a domain that only
      # declares the bare form keeps its real adapter under an
      # "isolated" fuzz boot. `projected_by` is dropped outright rather
      # than rebound, for every target adapter — `Registry
      # #read_repository` already falls back to the authoritative
      # repository when none exists, so a read model this ephemeral copy
      # never wires is simply unread, not broken.
      def rewrite_bindings!(copy, adapter_name)
        Dir.glob(File.join(copy, "**", "*.hecksagon")).each do |path|
          lines = File.readlines(path).grep_v(/\bprojected_by\s*\(?\s*"/)
          File.write(path, lines.join.gsub(/persisted_by\s*\(?\s*"[^"]+"\s*\)?/, "persisted_by(\"#{adapter_name}\")"))
        end
      end
    end
  end
end

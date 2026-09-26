require "fileutils"
require "tmpdir"
require "securerandom"

module Hecks
  module Fuzzing
    # A fresh, in-process adapter for every ephemeral boot.
    #
    # ## Why rebind at all
    #
    # Fuzzing/replay copies a domain to a tmpdir and boots from there
    # specifically to get zero-history state — `rm_rf`ing the copy's own
    # `data/` achieves that for a file-based adapter (Memory,
    # SqlitePersistence, Heki), because copying the directory copies the
    # store. It achieves nothing for an adapter that lives outside the
    # copied directory entirely — Postgres, named by a fixed connection
    # string in `.world` (examples/pizzas/bluebook/pizzas.world, for
    # instance). Copying the directory does not copy or isolate the
    # database, so a "fresh" boot against a Postgres-bound domain would
    # still see every record any other run, ever, wrote to it.
    #
    # So every `.hecksagon` in the copy gets its persistence binding
    # rewritten to Memory before booting, and any `projected_by` bind
    # dropped outright (optional — `Registry#read_repository` already
    # falls back to the authoritative repository when none exists). The
    # domain's own rules and shape are untouched ; only which adapter this
    # one ephemeral copy answers through changes. What the domain is
    # bound to for real deployment is never touched — only this tmp copy.
    #
    # ## `adapter:` modes
    #
    # `adapter:` (PRD 02) picks which real persistence one ephemeral boot
    # answers through. `:memory` is the default and the only mode every
    # caller that passes no `adapter:` still gets. `:sqlite` rebinds to
    # the real SQLite adapter instead of the in-memory one: 15 declared
    # properties (properties.rb) and every fuzz/replay run only ever
    # exercised Memory's own hand-written repository until this mode
    # existed, and `spec/adapters/query_agreement_spec.rb` already found 4
    # shipped query bugs from exactly that comparison, on a fixed corpus
    # far smaller than what the fuzzer generates. `:sqlite` rewrites to
    # `"SqlitePersistence"` — the name
    # `lib/hecks/adapters/driven/sqlite.adapter` actually registers under
    # (`Sqlite` is the class; `SqlitePersistence` is a thin subclass
    # that's the one real port binding names) — and needs no `.world`
    # settings at all, the same reason Memory needs none:
    # `Sqlite#resolve_path` already defaults an
    # unbound `database` setting to `"data/<table>.db"` relative to
    # `root:`, which `Hecks.boot(copy)` passes as this ephemeral copy's
    # own directory — a fresh, empty `data/` per run, exactly like
    # Memory's own zero-history guarantee, just backed by a real SQLite
    # file instead of a Hash. `:postgres` (PRD 02, docs/prds/02-fuzzer-
    # real-adapters.md) and `:postgres_era` (`rebind_to_postgres_era!`'s
    # own header, below) are the two real-Postgres modes. Each writes its
    # own fresh `.world` per `.hecksagon` rather than relying on the
    # zero-config default Sqlite/Memory get, and each needs a real,
    # reachable Postgres server: `:postgres` sources one shared,
    # permanent scratch database/schema this module itself owns (see
    # `FUZZ_POSTGRES_DATABASE`'s own header); `:postgres_era` instead
    # requires the caller to supply (and own the lifecycle of) its own
    # throwaway `database:`/`schema:`, since its only caller
    # (`bin/qa_sweep --persistence-parity`) already has to manage a
    # disposable database of its own, never a shared one this module could
    # safely default to.
    module IsolatedBoot
      module_function

      # PRD 02 (docs/future-features.md) — `adapter:` picks which real
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
      # `database:`/`schema:` are only meaningful for `adapter: :postgres_era`
      # — see `rebind_to_postgres_era!`'s own header for why that mode takes
      # caller-supplied connection identity instead of a hardcoded shared
      # constant the way `:postgres` does. Every other adapter ignores both;
      # accepting them unconditionally here (rather than a separate method
      # signature per adapter) keeps `SequenceGenerator`/`Replay`'s own
      # single passthrough (`adapter:`, now joined by these two) uniform
      # across all four modes.
      #
      # @param domain_path [String] path to the real domain directory to copy and isolate
      # @param adapter [Symbol] which persistence the copy answers through: `:memory`
      #   (default), `:sqlite`, `:postgres`, or `:postgres_era`
      # @param database [String, nil] the database name, required only for
      #   `adapter: :postgres_era`; ignored by every other adapter
      # @param schema [String, nil] the schema name, required only for
      #   `adapter: :postgres_era`; ignored by every other adapter
      # @yield [String] the freshly rebound copy's root directory, ready to boot
      # @yieldreturn [Object] anything; becomes this method's own return value
      # @return [Object] whatever the given block returns
      # @raise [ArgumentError] if `adapter` is not `:memory`, `:sqlite`, `:postgres`, or
      #   `:postgres_era`, or if `adapter: :postgres_era` is given without both
      #   `database:` and `schema:`
      def call(domain_path, adapter: :memory, database: nil, schema: nil)
        Dir.mktmpdir("hecks-fuzz") do |tmp|
          copy = File.join(tmp, File.basename(domain_path))
          copy_dereferencing(domain_path, copy)
          FileUtils.rm_rf(File.join(copy, "data"))
          case adapter
          when :memory       then rebind_to_memory!(copy)
          when :sqlite       then rebind_to_sqlite!(copy)
          when :postgres     then rebind_to_postgres!(copy)
          when :postgres_era then rebind_to_postgres_era!(copy, database: database, schema: schema)
          else raise ArgumentError,
                     "unknown fuzz adapter #{adapter.inspect} — :memory, :sqlite, :postgres, or :postgres_era"
          end
          yield copy
        end
      end

      # Symlinks are followed, not copied. `FileUtils.cp_r` reproduces a
      # symlink as a symlink, and a relative one then points at nothing
      # from a tmpdir — `lib/hecks/framework/bluebook/compliance
      # .bluebook` is exactly that, a link to
      # `examples/compliance/bluebook/compliance.bluebook`, so the whole
      # framework domain failed to boot here with a LoadError naming a
      # path under /var/folders that had never existed. Nothing about the
      # domain was wrong; the copy was.
      #
      # `FileUtils.cp` follows a symlink and copies its content, which is
      # what an isolated boot wants: the copy has to stand alone, since
      # rebind! rewrites files in it and must not reach back through a
      # link into the real tree.
      #
      # The vendored bluebook packages the domain's hecksagons name with
      # `uses_embryonaut_bluebook` are carried too — see `carry_vendored_bluebooks!`.
      #
      # @param source [String] the real domain directory to copy
      # @param destination [String] the tmpdir path to copy it into; created if missing
      # @return [void]
      def copy_dereferencing(source, destination)
        copy_files(source, destination)
        carry_vendored_bluebooks!(source, destination)
      end

      # Copies every file under `source` into `destination`, following symlinks.
      #
      # @param source [String] the directory to copy
      # @param destination [String] the path to copy it into; created if missing
      # @return [void]
      def copy_files(source, destination)
        FileUtils.mkdir_p(destination)
        Dir.glob(File.join(source, "**", "*"), File::FNM_DOTMATCH).each do |path|
          next if [".", ".."].include?(File.basename(path))

          target = File.join(destination, path.delete_prefix("#{source}/"))
          if File.directory?(path)
            FileUtils.mkdir_p(target)
          else
            FileUtils.mkdir_p(File.dirname(target))
            begin
              FileUtils.cp(path, target)
            rescue Errno::ENOENT
              # A transient sibling (an adapter's atomic-write `.tmp.<pid>`
              # file, caught mid-rename by the glob above) can vanish
              # between listing and copy — under parallel_r-spec two
              # workers share the real example tree. A file that no longer
              # exists was never part of the state this copy needs.
            end
          end
        end
      end

      # Copies the vendored bluebook packages the copy's hecksagons name into
      # the place a boot of the copy looks for them.
      #
      # `Hecks.boot` roots a registry at the parent of the directory it boots,
      # and `uses_embryonaut_bluebook "<name>"` loads from
      # `<root>/vendor/embryonaut_bluebooks/<name>/bluebook` (see
      # `EmbryonautBluebook.load!`). The copy holds only the domain directory,
      # so without this a target that vendors a package crashed the boot with
      # "no vendored embryonaut bluebook named ...". Only the packages a
      # hecksagon names are copied, never the rest of `vendor/`. A package the
      # source root does not have is skipped, so the boot's own error stands.
      #
      # @param source [String] the real domain directory
      # @param destination [String] the copy's directory; its parent is the copy's root
      # @return [void]
      def carry_vendored_bluebooks!(source, destination)
        names = Dir.glob(File.join(destination, "**", "*.hecksagon")).flat_map do |path|
          File.read(path).scan(/uses_embryonaut_bluebook\s*\(?\s*"([\w-]+)"/).flatten
        end
        names.uniq.each do |name|
          package = File.join(File.dirname(source), "vendor", "embryonaut_bluebooks", name)
          next unless File.directory?(package)

          copy_files(package, File.join(File.dirname(destination), "vendor", "embryonaut_bluebooks", name))
        end
      end

      # Rewrites every `.hecksagon` in the copy to bind through Memory and drops its
      # `.world` files, so the boot needs no settings at all.
      #
      # @param copy [String] the isolated copy's root directory
      # @return [void]
      def rebind_to_memory!(copy)
        rewrite_bindings!(copy, "Memory")
        strip_translations!(copy)

        # **The settings, not just the bind** — `WorldBuilder#method_missing`
        # stores a settings block under both "verb:adapter" and the bare
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

      # Same dance as memory, one adapter over — `Adapters::Sqlite#
      # resolve_path` (adapters/driven/sqlite.rb) defaults to
      # `data/<table>.db` under the boot's own root when no `database`
      # setting is declared, which `data/` already being cleared makes a
      # fresh on-disk store with zero configuration, the same "no .world
      # needed" property Memory has. `data/` itself is left for Sqlite to
      # recreate on first write, same as it always was for Memory/Heki —
      # nothing here creates it up front.
      #
      # @param copy [String] the isolated copy's root directory
      # @return [void]
      def rebind_to_sqlite!(copy)
        rewrite_bindings!(copy, "SqlitePersistence")
        strip_translations!(copy)
        Dir.glob(File.join(copy, "**", "*.world")).each { |path| File.delete(path) }
      end

      # **The expensive one** — Postgres has no zero-config default the way
      # Sqlite/Memory do (`Adapters::Postgres.connect_for` refuses outright
      # with no `database` setting), so dropping `.world` the way the
      # other two do would just move the WiringError from "wrong adapter"
      # to "no adapter." Every domain name this copy declares gets a
      # fresh `.world` written for it instead — not a rewrite of whatever
      # was there, a replacement, same reasoning `rewrite_bindings!`
      # already applies to `.hecksagon`: this ephemeral boot owns every
      # binding decision, nothing about a real deployment's own settings
      # is relevant or safe to half-preserve here.
      #
      # One shared schema, dropped and recreated before every boot — not a
      # fresh randomly-named one per call. `bin/fuzz` drives every
      # ephemeral boot sequentially (one `IsolatedBoot.call` fully exits
      # before the next begins — see that file's own single-threaded
      # `while` loop), so nothing is ever concurrent here ; a fresh name
      # every time would just leak schemas in `FUZZ_POSTGRES_DATABASE`
      # forever with nothing to ever drop them. If a caller ever does
      # start running fuzz adapters concurrently, this needs to move to a
      # process-unique schema name (`SecureRandom.hex` is already
      # `require`d here for exactly that day) — flagged, not solved,
      # since nothing today calls this from more than one thread.
      FUZZ_POSTGRES_DATABASE = "hecks_fuzz".freeze
      FUZZ_POSTGRES_SCHEMA   = "hecks_fuzz".freeze

      # Rewrites every `.hecksagon` in the copy to bind through Postgres, against the
      # shared `FUZZ_POSTGRES_DATABASE`/`FUZZ_POSTGRES_SCHEMA` scratch schema.
      #
      # @param copy [String] the isolated copy's root directory
      # @return [void]
      def rebind_to_postgres!(copy)
        require "pg"
        rewrite_bindings!(copy, "Postgres")
        strip_translations!(copy)
        ensure_fuzz_schema!

        # One `.world` per directory a `.hecksagon` actually lives in, not
        # one at `copy`'s own root — `Folder#load_domain` resolves a
        # single `bluebook_directory` and globs `*.world` there, non-
        # recursively (`Folder#load_each`); a domain can hold several
        # `Hecks.hecksagon "<Name>" do ... end` sibling blocks in that one
        # file (banking.hecksagon declares "Banking", "Governance", and
        # "Identity" together), so every name found in one directory
        # is bundled into one `.world` written there, not scattered by name.
        write_worlds!(copy, "hecks_fuzz_postgres.world") do |name|
          <<~WORLD
            Hecks.world "#{name}" do
              persisted_by("Postgres") do
                database "#{FUZZ_POSTGRES_DATABASE}"
                schema "#{FUZZ_POSTGRES_SCHEMA}"
              end
            end
          WORLD
        end
      end

      # Admin connection lives outside the tmp copy entirely — same as
      # every other real-Postgres spec in this repo (`support/
      # postgres_probe.rb`'s own header). Database created once per
      # process and remembered (`@fuzz_database_ready` on this module's
      # own singleton, the same memoization shape `PostgresProbe
      # .available?` already uses) ; the schema inside it is dropped and
      # recreated on every call, which is what actually isolates one
      # ephemeral boot's data from the next.
      #
      # @return [void]
      def ensure_fuzz_schema!
        # `Adapters::Postgres#initialize` opens one real `PG::Connection`
        # per aggregate and never explicitly closes it — fine for a
        # process that boots once and runs, exactly what every other
        # caller of this adapter is. A fuzz run boots dozens to hundreds
        # of ephemeral times in one process (every seed does at least a
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
        # connection the previous boot's now-unreferenced adapters held,
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
        # **Quiet on purpose** — same as `Adapters::Postgres.connect_for`'s
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

      # The adapter `:postgres` never touches — `Postgres` and `PostgresEra`
      # are sibling, not interchangeable, adapters (see postgres_era.rb's
      # own header: "the only one that declares the LINEAGE capability").
      # PRD 02 (docs/prds/02-fuzzer-real-adapters.md) shipped `:postgres`
      # and explicitly scoped `PostgresEra` out: "nothing here touches
      # era/lineage machinery." That gap is real, not cosmetic —
      # `examples/directory` (a `compute`/`rekey` translation edge, the
      # one domain in this corpus that actually exercises PostgresEra-
      # bound SQL compilation) had to be shelved out of `hecks_qa`'s own
      # rotation for exactly this reason: every existing fuzz/replay path,
      # `:memory` included, structurally cannot reach it. This mode closes
      # that — `bin/qa_sweep --persistence-parity` is its first caller.
      #
      # No shared constant database, unlike `:postgres` above — deliberate.
      # `rebind_to_postgres!`'s own `FUZZ_POSTGRES_DATABASE`/`_SCHEMA` are
      # module-level constants because `bin/fuzz --adapter postgres` is a
      # general-purpose, run-it-anytime tool with no caller-tracked
      # lifecycle of its own. This mode's only caller
      # (`bin/qa_sweep --persistence-parity`) is different: it dispatches
      # through `QualityControl::Target.claim!`'s own cross-process lock
      # first (see that script's own header), so at most one sweep is ever
      # touching a given target's own disposable database at a time — but
      # the caller, not this module, is what owns that database's name and
      # lifecycle (created, and genuinely dropped, by the caller itself),
      # exactly the discipline `spec/support/qa_sweep_all_fixture.rb`'s own header
      # describes and this repository's persistence-parity work is
      # required to follow. Accepting `database:`/`schema:` as required
      # keyword arguments (never a fallback constant) is what keeps that
      # ownership from silently drifting back onto this module the way
      # `:postgres`'s own `FUZZ_POSTGRES_DATABASE` already has.
      #
      # @param copy [String] the isolated copy's root directory
      # @param database [String] the caller-owned throwaway database name
      # @param schema [String] the caller-owned throwaway schema name
      # @return [void]
      # @raise [ArgumentError] if `database` or `schema` is empty
      def rebind_to_postgres_era!(copy, database:, schema:)
        require "pg"
        if database.to_s.empty? || schema.to_s.empty?
          raise ArgumentError,
                "adapter: :postgres_era requires both database: and schema: — a throwaway database/schema " \
                "THIS CALLER creates and drops itself (see rebind_to_postgres_era!'s own header). " \
                "There is no shared default, unlike :postgres, so the caller cannot forget to own the lifecycle."
        end

        rewrite_bindings!(copy, "PostgresEra")
        ensure_postgres_era_schema!(database: database, schema: schema)

        # Same one-`.world`-per-`.hecksagon`-directory shape `rebind_to_
        # postgres!` uses, for the identical reason (`Folder#
        # load_domain` globs `*.world` non-recursively) — see
        # `write_worlds!`. `PostgresEra`
        # additionally takes `schema:` (postgres_era.rb's own "shared-
        # instance isolation" comment): the caller-supplied throwaway
        # schema is what actually isolates this one ephemeral boot from
        # the next, the same job `FUZZ_POSTGRES_SCHEMA` does for `:postgres`
        # — `connect_for` itself idempotently `CREATE SCHEMA IF NOT
        # EXISTS`s it, so this method only ever needs to drop it first
        # (in `ensure_postgres_era_schema!`, below) for the zero-history
        # guarantee every other adapter mode already gives.
        #
        # `allow_superuser true` — on the record, on purpose. A bare
        # `database` connects as the ambient Postgres user, and
        # PostgresEra refuses to boot at all when that user is a
        # superuser (its era write-fence is row-level security, which a
        # superuser walks through — `Lineage#check_fence_applies!`,
        # BUG#24). That refusal protects a real ledger from an old
        # checkout's stale writes; nothing here is one. This is an
        # ephemeral boot into a throwaway schema the caller itself
        # creates and drops, whose data no second checkout ever shares,
        # and what it compares is Memory's answers against PostgresEra's
        # own SQL — the era fence is not under test and cannot be
        # crossed. So opt in explicitly rather than make every
        # persistence-parity run first provision a fenced role for a
        # database it is about to throw away; the one-line warning
        # PostgresEra prints per boot under the opt-in is the honest
        # price. Inert on a machine whose ambient user is ordinary.
        write_worlds!(copy, "hecks_fuzz_postgres_era.world") do |name|
          <<~WORLD
            Hecks.world "#{name}" do
              persisted_by("PostgresEra") do
                database "#{database}"
                schema "#{schema}"
                allow_superuser true
              end
            end
          WORLD
        end
      end

      # Writes one `.world` file per directory that holds a `.hecksagon`, naming every
      # `Hecks.hecksagon` block found in that directory, and deletes every other `.world`
      # in the copy.
      #
      # One world file per directory, every hecksagon name in that directory — never one
      # write per `*.hecksagon` file. A domain's `context_map.hecksagon` sits beside its
      # main hecksagon (the `qa` domain declares Governance in one and QualityControl in
      # the other), and a second `File.write` to the same world path would drop the first
      # file's names, leaving that domain bound to Postgres with no `database` to open.
      #
      # Any `.world` the copy shipped with (a real deployment's own connection string) is
      # redundant with, and would conflict with (`Registry#add_world`'s own header, on
      # loading the same domain name twice), the fresh one written here, so it goes the same
      # way `rebind_to_memory!` sends every `.world` in a Memory-mode boot.
      #
      # @param copy [String] the isolated copy's root directory
      # @param world_file [String] the basename of the world file written in each directory
      # @yield [name] builds the world text for one hecksagon name
      # @yieldparam name [String] a domain name a `Hecks.hecksagon` block in the directory declares
      # @yieldreturn [String] the `Hecks.world` block for that name
      # @return [void]
      def write_worlds!(copy, world_file, &world_for)
        names_by_dir = Hash.new { |hash, dir| hash[dir] = [] }
        Dir.glob(File.join(copy, "**", "*.hecksagon")).each do |hecksagon_path|
          names = File.read(hecksagon_path).scan(/Hecks\.hecksagon\s+"([^"]+)"/).flatten
          names_by_dir[File.dirname(hecksagon_path)].concat(names)
        end
        names_by_dir.each do |dir, names|
          next if names.empty?

          File.write(File.join(dir, world_file), names.uniq.map(&world_for).join("\n"))
        end

        Dir.glob(File.join(copy, "**", "*.world")).each do |path|
          File.delete(path) unless File.basename(path) == world_file
        end
      end

      # The zero-history guarantee for this mode — `DROP SCHEMA ... CASCADE`
      # before every ephemeral boot, mirroring `ensure_fuzz_schema!` above
      # (same `GC.start`-before-connecting fix for the identical
      # `max_connections` exhaustion that method's own comment documents —
      # `PostgresEra` opens real `PG::Connection`s exactly like `Postgres`
      # does, same unclosed-until-GC'd lifetime). The database itself is
      # created here too, idempotently (`CREATE DATABASE IF NOT EXISTS`
      # has no Postgres spelling, hence the existence check) — but never
      # dropped here: this module creates it once per process because
      # `Hecks.boot` needs it to exist before `PostgresEra.connect_for`'s
      # own `PG.connect(dbname: ...)` can succeed at all, but dropping it
      # again is the caller's own job (its name and lifecycle belong to
      # the caller — see `rebind_to_postgres_era!`'s own header), not
      # something this per-ephemeral-boot helper should ever do mid-sweep.
      #
      # @param database [String] the caller-owned database name, created if it does not
      #   already exist
      # @param schema [String] the caller-owned schema name, dropped and recreated
      # @return [void]
      def ensure_postgres_era_schema!(database:, schema:)
        GC.start

        admin = PG.connect(dbname: "postgres")
        exists = admin.exec_params(
          "SELECT 1 FROM pg_database WHERE datname = $1", [database]
        ).ntuples.positive?
        admin.exec(%(CREATE DATABASE "#{database}")) unless exists
        admin.close

        db = PG.connect(dbname: database)
        db.exec("SET client_min_messages = warning")
        quoted = db.quote_ident(schema)
        db.exec("DROP SCHEMA IF EXISTS #{quoted} CASCADE")
        db.close
      end

      # The shared rewrite — factored out of `rebind_to_memory!` when
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
      # A `compute`/`rekey` translation edge refuses to boot at all under
      # any non-lineage-capable adapter — found live, wiring this very
      # mode up against `examples/directory`: `Runtime::EraCheck
      # .check_compute_rules!` (era_check.rb) runs unconditionally for
      # every loaded bluebook once the era plugin is loaded at all
      # (`bin/qa_sweep`'s own top-of-file `require "hecks/ports/
      # persistence/plugins/era"`, needed for the ledger's own
      # PostgresEra-bound aggregates), and refuses outright — "compute
      # rules require the Postgres adapter" — for any aggregate whose
      # lineage carries a `compute` rule and whose bound adapter is not
      # lineage-capable. `PostgresEra` is the only adapter that answers
      # `lineage_capable? == true` (postgres_era.rb's own `self.
      # lineage_capable? = true`) — plain `Postgres` does not, so this
      # refusal was already real for `:postgres`/`:sqlite`/`:memory`
      # alike, for any domain with a translation edge, before this
      # mode's own `:postgres_era` ever existed. This is very likely the
      # mechanical reason `examples/directory` had to be shelved out of
      # `hecks_qa`'s own rotation in the first place — not merely "less
      # interesting to fuzz on Memory," but "cannot boot on Memory at
      # all" once the era plugin is loaded, which every real
      # `bin/qa_sweep` invocation already does.
      #
      # The fix is to drop the edge, not to chase the refusal — an
      # ephemeral, zero-history replay boot (every mode `IsolatedBoot`
      # offers) never has a pre-existing era-1 row to translate in the
      # first place, so the translation edge is irrelevant to anything a
      # fuzz/replay run actually exercises (ordinary command dispatch
      # against a fresh boot) — it only ever matters at mint time,
      # against a real, pre-existing database
      # (`PostgresEra::LineageManager.check!`, a wholly separate,
      # human-approved path this harness was never meant to reach).
      # Dropping it here is exactly the same move `rebind_to_memory!`
      # already makes for `.world` (irrelevant/conflicting settings for
      # an ephemeral boot, deleted outright) — never called for
      # `:postgres_era` itself, where the bound adapter genuinely is
      # lineage-capable and the edge causes no refusal to begin with.
      #
      # @param copy [String] the isolated copy's root directory
      # @return [void]
      def strip_translations!(copy)
        Dir.glob(File.join(copy, "**", "translations", "*.bluebook")).each { |path| File.delete(path) }
      end

      # Rewrites every `persisted_by` bind — aggregate-scoped or bare at the
      # hecksagon's own root, naming its adapter as a literal or through a local
      # variable — in the copy's `.hecksagon` files to name `adapter_name`,
      # and drops every `projected_by` bind outright.
      #
      # @param copy [String] the isolated copy's root directory
      # @param adapter_name [String] the port binding name to rewrite every
      #   `persisted_by` to, such as `"Memory"` or `"SqlitePersistence"`
      # @return [void]
      def rewrite_bindings!(copy, adapter_name)
        Dir.glob(File.join(copy, "**", "*.hecksagon")).each do |path|
          lines = File.readlines(path).grep_v(/\bprojected_by\s*\(?\s*"/)
          bind = /persisted_by\s*\(?\s*(?:"[^"]+"|[a-z_]\w*)\s*\)?/
          File.write(path, lines.join.gsub(bind, "persisted_by(\"#{adapter_name}\")"))
        end
      end
    end
  end
end

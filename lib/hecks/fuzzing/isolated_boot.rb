require "fileutils"
require "tmpdir"
require "securerandom"
require_relative "outside_world"
require_relative "../runtime/adapter_lookup"

module Hecks
  module Fuzzing
    # Rewrites a copied domain's persistence bindings before an ephemeral
    # fuzz/replay boot; a directory copy alone does not isolate Postgres state.
    module IsolatedBoot
      module_function

      # Copies `domain_path` to a tmpdir, rebinds its persistence to `adapter`, and
      # yields the copy's root. `:postgres` is expensive: use smaller seed/step counts.
      #
      # The block runs with `OutsideWorld` standing in for every adapter a port or a port-answered
      # query reaches: a fuzz or replay checks the domain's own rules, and the adapters of the
      # chapters that drive tools would run shells and write files from a generated sequence.
      def call(domain_path, adapter: :memory, database: nil, schema: nil, scratch: {})
        Dir.mktmpdir("hecks-fuzz") do |tmp|
          copy = File.join(tmp, File.basename(domain_path))
          copy_dereferencing(domain_path, copy)
          FileUtils.rm_rf(File.join(copy, "data"))
          case adapter
          when :memory       then rebind_to_memory!(copy)
          when :sqlite       then rebind_to_sqlite!(copy)
          when :postgres     then rebind_to_postgres!(copy, **scratch)
          when :postgres_era then rebind_to_postgres_era!(copy, database: database, schema: schema)
          else raise ArgumentError,
                     "unknown fuzz adapter #{adapter.inspect} — :memory, :sqlite, :postgres, or :postgres_era"
          end
          Runtime::AdapterLookup.standing_in(OutsideWorld) { yield copy }
        end
      end

      # Copies `source` into `destination`, following symlinks rather than reproducing
      # them (cp_r would copy a symlink as a symlink, dangling once the source tree is
      # gone), and carries any vendored bluebooks the copy's hecksagons name.
      def copy_dereferencing(source, destination)
        copy_files(source, destination)
        carry_vendored_bluebooks!(source, destination)
      end

      # Copies every file under `source` into `destination`, following symlinks.
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
              # A sibling can vanish between listing and copy under parallel workers;
              # skip a file that's already gone.
            end
          end
        end
      end

      # Copies vendored bluebook packages a copy's hecksagons name into the copy, since
      # `Hecks.boot` only sees the domain directory itself, not `vendor/`.
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

      # Rewrites every `.hecksagon` in the copy to bind through Memory and replaces its
      # `.world` files with a `default_adapter "Memory"` one, so the boot needs no settings.
      def rebind_to_memory!(copy)
        rewrite_bindings!(copy, "Memory")
        strip_translations!(copy)

        # Also replaces the settings, not just the bind: a bare fallback setting (like
        # Postgres's `database:`) would otherwise still apply and WiringError refuses it.
        write_default_worlds!(copy, "Memory")
      end

      # Same as `rebind_to_memory!`, one adapter over — Sqlite also needs no `.world`
      # settings, since `Sqlite#resolve_path` defaults `database` to `data/<table>.db`.
      def rebind_to_sqlite!(copy)
        rewrite_bindings!(copy, "SqlitePersistence")
        strip_translations!(copy)
        write_default_worlds!(copy, "SqlitePersistence")
      end

      # Postgres has no zero-config default (Postgres.connect_for refuses without a
      # `database` setting), so every domain name gets a fresh `.world` written for it.
      # One shared schema, dropped and recreated per boot, not a fresh name per call —
      # safe only because callers run one ephemeral boot at a time.
      FUZZ_POSTGRES_DATABASE = "hecks_fuzz".freeze
      FUZZ_POSTGRES_SCHEMA   = "hecks_fuzz".freeze

      # Rewrites every `.hecksagon` in the copy to bind through Postgres, against the
      # shared scratch schema unless the caller names its own via `scratch:`.
      def rebind_to_postgres!(copy, database: nil, schema: nil)
        require "pg"
        database ||= FUZZ_POSTGRES_DATABASE
        schema   ||= FUZZ_POSTGRES_SCHEMA
        rewrite_bindings!(copy, "Postgres")
        strip_translations!(copy)
        ensure_fuzz_schema!(database, schema)

        # One `.world` per directory a `.hecksagon` lives in, not one at the copy's
        # root — `Folder#load_domain` globs `*.world` non-recursively.
        write_worlds!(copy, "hecks_fuzz_postgres.world") do |name|
          <<~WORLD
            Hecks.world "#{name}" do
              default_adapter "Postgres"
              persisted_by("Postgres") do
                database "#{database}"
                schema "#{schema}"
              end
            end
          WORLD
        end
        write_unbound_chapter_worlds!(copy)
      end

      # Creates `database` once per process (memoized) and drops/recreates `schema`
      # inside it on every call — that's what isolates one ephemeral boot from the next.
      def ensure_fuzz_schema!(database = FUZZ_POSTGRES_DATABASE, schema = FUZZ_POSTGRES_SCHEMA)
        # PG::Connection only closes its socket when GC finalizes it, and a tight fuzz
        # loop opens connections faster than GC reclaims them — without this, a run
        # exhausts Postgres's max_connections after a few dozen ephemeral boots.
        GC.start

        @fuzz_databases_ready ||= {}
        unless @fuzz_databases_ready[database]
          admin = PG.connect(dbname: "postgres")
          exists = admin.exec_params(
            "SELECT 1 FROM pg_database WHERE datname = $1", [database]
          ).ntuples.positive?
          admin.exec(%(CREATE DATABASE "#{database}")) unless exists
          admin.close
          @fuzz_databases_ready[database] = true
        end

        db = PG.connect(dbname: database)
        # Quiet on purpose: an ordinary DROP CASCADE NOTICEs per dropped object, which
        # would bury hecks fuzz's own output on every boot after the first.
        db.exec("SET client_min_messages = warning")
        quoted = db.quote_ident(schema)
        db.exec("DROP SCHEMA IF EXISTS #{quoted} CASCADE")
        db.exec("CREATE SCHEMA #{quoted}")
        db.close
      end

      # `:postgres_era` is the only mode that exercises era/lineage-bound SQL; plain
      # `:postgres` never touches that machinery. Unlike `:postgres`, there's no shared
      # scratch constant here — `database:`/`schema:` are required keyword args because
      # the caller (`hecks quality_control ask run --persistence-parity`) owns that database's
      # lifecycle.
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

        # `schema:` isolates one ephemeral boot from the next, the same job
        # `FUZZ_POSTGRES_SCHEMA` does for `:postgres` (`connect_for` idempotently
        # creates it; this method only needs to drop it first, in
        # `ensure_postgres_era_schema!`).
        #
        # `allow_superuser true` is deliberate: PostgresEra normally refuses to boot as
        # a superuser (its era write-fence is row-level security, which a superuser
        # bypasses), to protect a real ledger from stale writes. This is a throwaway
        # schema the caller creates and drops, comparing Memory against PostgresEra's
        # SQL — the era fence isn't under test, so opting in here is safe.
        write_worlds!(copy, "hecks_fuzz_postgres_era.world") do |name|
          <<~WORLD
            Hecks.world "#{name}" do
              default_adapter "PostgresEra"
              persisted_by("PostgresEra") do
                database "#{database}"
                schema "#{schema}"
                allow_superuser true
              end
            end
          WORLD
        end
        write_unbound_chapter_worlds!(copy)
      end

      # Replaces every `.world` in the copy with one that declares only `default_adapter`,
      # so an aggregate left unbound by its hecksagon still falls back to `adapter_name`.
      def write_default_worlds!(copy, adapter_name)
        write_worlds!(copy, "hecks_fuzz_default.world") do |name|
          <<~WORLD
            Hecks.world "#{name}" do
              default_adapter "#{adapter_name}"
            end
          WORLD
        end
      end

      # Gives every chapter with no hecksagon block (so no bind) a world of its own that
      # falls back to Memory, since the worlds `write_worlds!` wrote require a database
      # a chapter with no bind can't provide.
      def write_unbound_chapter_worlds!(copy)
        named = Dir.glob(File.join(copy, "**", "*.hecksagon")).flat_map do |path|
          File.read(path).scan(/Hecks\.hecksagon\s+"([^"]+)"/).flatten
        end
        bluebooks = Dir.glob(File.join(copy, "**", "*.bluebook")).group_by { |path| File.dirname(path) }
        bluebooks.each do |dir, files|
          unbound = files.flat_map { |path| File.read(path).scan(/Hecks\.bluebook[\s(]+"([^"]+)"/).flatten }
                         .uniq - named
          named.concat(unbound)
          next if unbound.empty?

          worlds = unbound.map { |name| %(Hecks.world "#{name}" do\n  default_adapter "Memory"\nend\n) }
          File.write(File.join(dir, "hecks_fuzz_unbound.world"), worlds.join("\n"))
        end
      end

      # Writes one `.world` per directory holding a `.hecksagon`, naming every
      # `Hecks.hecksagon` block found there, and deletes every other `.world` in the
      # copy. One write per directory, not per file — a domain can split hecksagon
      # blocks (e.g. `context_map.hecksagon` beside the main one) across sibling files
      # in the same directory, and a second `File.write` to the same path would drop
      # the first file's names.
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

      # Mirrors `ensure_fuzz_schema!`'s GC.start-before-connecting fix for the same
      # max_connections exhaustion. Creates `database` if missing, but never drops
      # it — that's the caller's job (see `rebind_to_postgres_era!`).
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

      # Deletes every `translations/*.bluebook` in the copy. A compute/rekey translation
      # edge refuses to boot under any non-lineage-capable adapter (only `PostgresEra`
      # answers `lineage_capable? == true`), so every other mode strips it here rather
      # than tripping that refusal. Safe to drop: an ephemeral, zero-history boot never
      # has a pre-existing era-1 row to translate — the edge only matters at mint time,
      # against a real database, never here.
      def strip_translations!(copy)
        Dir.glob(File.join(copy, "**", "translations", "*.bluebook")).each { |path| File.delete(path) }
      end

      # Rewrites every `persisted_by` bind — aggregate-scoped or bare at the hecksagon's
      # own root, naming its adapter as a literal or through a local variable — to name
      # `adapter_name`, and drops every `projected_by` bind outright (unread rather than
      # broken, since `Registry#read_repository` falls back to the authoritative repo).
      def rewrite_bindings!(copy, adapter_name)
        Dir.glob(File.join(copy, "**", "*.hecksagon")).each do |path|
          lines = File.readlines(path).grep_v(/\bprojected_by\s*\(?\s*"/)
          # Horizontal space only: a newline ends the statement, and the next one must stay.
          bind = /persisted_by[ \t]*\(?[ \t]*(?:"[^"]+"|[a-z_]\w*)[ \t]*\)?/
          File.write(path, lines.join.gsub(bind, "persisted_by(\"#{adapter_name}\")"))
        end
      end
    end
  end
end

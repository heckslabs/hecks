# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaSweep
      # The disposable Postgres schemas the parity and concurrency modes run in: created before the
      # seeds and dropped once the sweep ends, however it ends.
      module Scratch
        private

        # Safe under concurrent callers: several sweeps can reach this at once (the parity wave
        # runs up to `QualityControlDials::SWEEP_MAX_PARALLEL` targets in parallel), so the
        # existence check is only a fast-path optimization; the actual safety net is rescuing the
        # create's own race, since two processes can both see the database missing and both attempt
        # `CREATE DATABASE`. Postgres reports that race two different ways: a `duplicate_database`
        # error (42P04) from its own pre-create name check, or, when two backends run that check at
        # nearly the same instant, a raw `unique_violation` (23505) on `pg_database`'s name index
        # once both proceed to insert.
        def ensure_scratch_database!(name)
          admin = PG.connect(dbname: "postgres")
          exists = admin.exec_params("SELECT 1 FROM pg_database WHERE datname = $1", [name]).ntuples.positive?
          admin.exec(%(CREATE DATABASE "#{name}")) unless exists
        rescue PG::DuplicateDatabase, PG::UniqueViolation
          nil
        ensure
          admin&.close
        end

        # The scratch database is a fixed name, created if missing and never dropped (a concurrent
        # sweep may use another schema in it); only this run's uniquely named schemas are dropped,
        # in `drop_scratch_schemas`. `concurrency` needs two: the real fork race and its sequential
        # oracle.
        def prepare_scratch_schemas
          @parity_database = @concurrency_database = SCRATCH_DATABASE
          @parity_schema = @race_schema = @reference_schema = nil
          prepare_parity_schema if @active_modes.include?(:persistence_parity)
          prepare_concurrency_schemas if @active_modes.include?(:concurrency)
        end

        def prepare_parity_schema
          require "pg"
          @parity_schema = "qa_pp_#{@target_reference}_#{Process.pid}_#{SecureRandom.hex(4)}"
          ensure_scratch_database!(@parity_database)
        end

        def prepare_concurrency_schemas
          require "pg"
          @race_schema = "qa_cc_race_#{@target_reference}_#{Process.pid}_#{SecureRandom.hex(4)}"
          @reference_schema = "qa_cc_ref_#{@target_reference}_#{Process.pid}_#{SecureRandom.hex(4)}"
          ensure_scratch_database!(@concurrency_database)
        end

        def drop_scratch_schemas
          drop_schemas(@parity_database, [@parity_schema]) if @parity_schema
          drop_schemas(@concurrency_database, [@race_schema, @reference_schema]) if @race_schema || @reference_schema
        end

        def drop_schemas(database, schemas)
          admin = PG.connect(dbname: database)
          admin.exec("SET client_min_messages = warning")
          schemas.compact.each { |schema| admin.exec("DROP SCHEMA IF EXISTS #{admin.quote_ident(schema)} CASCADE") }
          admin.close
        end
      end
    end
  end
end

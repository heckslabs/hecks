require "fileutils"
require "digest"
require "json"

module Hecksagain
  module Ports
    module Persistence
      # The held era texts for one domain — the storage facts eras are
      # made of. Each era's bluebook source is written once, at the first
      # boot of that era, and frozen forever; era NAMES (hash + short
      # label) are minted once, by the Ruby scaffold, and stored beside
      # the texts — nothing ever recomputes a stored name to verify it.
      # File adapters share this store under `<root>/data/eras/<domain>/`
      # (a file beside a heki journal); Postgres keeps the same facts in
      # its `hecks_eras` table instead.
      class EraStore
        NAMES = "names.tsv".freeze
        INTEGRITY = "integrity.tsv".freeze

        attr_reader :dir

        def initialize(root, domain_name)
          @domain = domain_name.to_s
          @dir = File.join(root.to_s, "data", "eras", Naming.snake(domain_name))
        end

        # [[ordinal, source text], ...] sorted by ordinal — every era this
        # store has ever held, era 1 first. Each text is verified against
        # its INTEGRITY digest on the way out: the era name is minted
        # from the projection and never recomputed, but the held BYTES
        # are a storage fact, and an edited storage fact must refuse —
        # silently reporting "no drift" over doctored text is exactly
        # the disease this whole machinery exists to cure. A missing
        # digest (a store from before this check) is backfilled, not
        # refused.
        def held_texts
          Dir[File.join(@dir, "*.bluebook")]
            .map { |path| [File.basename(path, ".bluebook").to_i, path] }
            .select { |ordinal, _| ordinal.positive? }
            .sort_by(&:first)
            .map { |ordinal, path| [ordinal, verify_integrity!(ordinal, File.read(path))] }
        end

        def held_path(ordinal) = File.join(@dir, "#{ordinal}.bluebook")

        def hold!(ordinal, text, projection: nil)
          FileUtils.mkdir_p(@dir)
          if File.exist?(held_path(ordinal))
            raise Runtime::WiringError,
                  "era #{ordinal} of #{File.basename(@dir)} is already held — held texts are frozen forever"
          end

          File.write(held_path(ordinal), text)
          record_integrity!(ordinal, text)
          record_projection!(ordinal, projection) if projection
          archive!(ordinal, text)
        end

        def hold_first!(text, projection: nil) = hold!(1, text, projection: projection)

        # The frozen SHAPE beside the frozen text — what lets EITHER
        # runtime, at 3am, answer "did the edit change what this era
        # meant, or only its words?" by the structural comparison it
        # already trusts, without hashing or canonical serialization.
        def projection_path(ordinal) = File.join(@dir, "#{ordinal}.projection.json")

        def stored_projection(ordinal)
          return nil unless File.exist?(projection_path(ordinal))

          JSON.parse(File.read(projection_path(ordinal)))
        end

        def record_projection!(ordinal, projection)
          return if File.exist?(projection_path(ordinal))

          File.write(projection_path(ordinal), JSON.generate(projection))
        end

        # Every frozen text version, archived where an edit cannot reach
        # it — the recovery the hard reattest refusal points at. Append
        # only; content-addressed by digest, so re-archiving is a no-op
        # and a re-attested text lands beside the original it replaced.
        def archive!(ordinal, text)
          archive_dir = File.join(@dir, "archive")
          FileUtils.mkdir_p(archive_dir)
          path = File.join(archive_dir, "#{ordinal}-#{digest_of(text)[0, 12]}.bluebook")
          File.write(path, text) unless File.exist?(path)
          path
        end

        # {ordinal => {hash:, label:}} — only ever written by mint!.
        def names
          path = File.join(@dir, NAMES)
          return {} unless File.exist?(path)

          File.readlines(path, chomp: true).reject(&:empty?).to_h do |line|
            ordinal, hash, label, form = line.split("\t")
            # lines written before the form field carry an implicit 1 —
            # form 1 was the only form in existence
            [ordinal.to_i, { hash: hash, label: label, form: (form || 1).to_i }]
          end
        end

        def label_for(ordinal) = names.dig(ordinal, :label)

        # Mints an era's identity — ONCE. Called only from the Ruby
        # scaffold's side of the world; a name, once stored, is never
        # re-derived, so the canonical serialization is free to evolve.
        def mint!(ordinal, bluebook)
          existing = label_for(ordinal)
          return existing if existing

          FileUtils.mkdir_p(@dir)
          hash = Runtime::StorageShape.mint_hash(bluebook)
          label = hash[0, Runtime::StorageShape::LABEL_LENGTH]
          File.open(File.join(@dir, NAMES), "a") do |file|
            file.puts "#{ordinal}\t#{hash}\t#{label}\t#{Runtime::StorageShape::FORM_VERSION}"
          end
          label
        end

        def digest_of(text) = Digest::SHA256.hexdigest(text)

        # The recovery path after the integrity check fires. The digest
        # is tamper-EVIDENCE against accident and drift, not against an
        # adversary (anyone who can edit the text can recompute the
        # digest beside it) — so recovery is a human acknowledgment, not
        # a security ceremony: re-attest records the old and new digests
        # in an append-only attestation log and re-freezes the text as
        # it now stands. bin/reattest_era is the only caller; it shows
        # the operator the text and demands --accept first.
        ATTESTATIONS = "attestations.tsv".freeze

        def raw_text(ordinal)
          File.exist?(held_path(ordinal)) ? File.read(held_path(ordinal)) : nil
        end

        def stored_digest(ordinal) = integrity_digests[ordinal]

        def reattest!(ordinal)
          text = raw_text(ordinal)
          raise Runtime::WiringError, "#{@domain} holds no era #{ordinal} to re-attest" unless text

          old_digest = integrity_digests[ordinal]
          fresh = digest_of(text)
          rewritten = integrity_digests.merge(ordinal => fresh)
          File.write(
            File.join(@dir, INTEGRITY),
            rewritten.sort.map { |o, digest| "#{o}\t#{digest}" }.join("\n") + "\n"
          )
          File.open(File.join(@dir, ATTESTATIONS), "a") do |file|
            file.puts "#{ordinal}\t#{old_digest}\t#{fresh}\t#{Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')}"
          end
          archive!(ordinal, text)
          fresh
        end

        private

        def integrity_digests
          path = File.join(@dir, INTEGRITY)
          return {} unless File.exist?(path)

          File.readlines(path, chomp: true).reject(&:empty?).to_h do |line|
            ordinal, digest = line.split("\t")
            [ordinal.to_i, digest]
          end
        end

        def record_integrity!(ordinal, text)
          return if integrity_digests.key?(ordinal)

          File.open(File.join(@dir, INTEGRITY), "a") { |file| file.puts "#{ordinal}\t#{digest_of(text)}" }
        end

        def verify_integrity!(ordinal, text)
          stored = integrity_digests[ordinal]
          if stored.nil?
            record_integrity!(ordinal, text)
            backfill_frozen_facts!(ordinal, text)
            return text
          end
          if stored == digest_of(text)
            backfill_frozen_facts!(ordinal, text)
            return text
          end

          raise Runtime::WiringError, EraTamper.refusal(
            domain: @domain, ordinal: ordinal, edited_text: text,
            stored_projection: stored_projection(ordinal), source_path: held_path(ordinal)
          )
        end

        # A verified-authentic text backfills what older stores lack:
        # its projection and its archive copy. Never run on a text that
        # failed verification — that would bless the edit.
        def backfill_frozen_facts!(ordinal, text)
          archive!(ordinal, text)
          return if File.exist?(projection_path(ordinal))

          projection = EraTamper.project(text, held_path(ordinal))
          record_projection!(ordinal, projection) if projection
        end
      end
    end
  end
end

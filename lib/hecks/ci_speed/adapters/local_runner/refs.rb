# frozen_string_literal: true

require "open3"
require "hecks/ci_speed/adapters/local_runner/refused"

module Hecks
  module Adapters
    class LocalRunner
      # Turns the two refs an experiment names into the commits they stand for, in the repository
      # that asked.
      module Refs
        module_function

        # @param root [String] the repository whose refs these are
        # @param asked [Hash{Symbol => Object}] the experiment's `base_ref` and `candidate_ref`
        # @return [Hash{Symbol => String}] each side's commit
        # @raise [Refused] when a ref names no commit, or both name the same one
        def resolve(root, asked)
          shas = { base: sha_of(root, asked.fetch(:base_ref)), candidate: sha_of(root, asked.fetch(:candidate_ref)) }
          return shas unless shas.values.uniq.one?

          raise Refused, "base ref #{asked[:base_ref]} and candidate ref #{asked[:candidate_ref]} " \
                         "are the same commit, #{shas[:base]}"
        end

        # @param root [String] the repository
        # @param ref [String] a ref git can resolve
        # @return [String] the commit it names
        # @raise [Refused] when it names none
        def sha_of(root, ref)
          out, status = Open3.capture2e("git", "-C", root, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
          raise Refused, "#{ref.inspect} names no commit in #{root}" unless status.success?

          out.strip
        end
      end
    end
  end
end

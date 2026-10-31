# frozen_string_literal: true

require "fileutils"

module Hecks
  module Translation
    # Carries out an admitted `Reconcile` plan on the translations directory, and puts the files
    # back when the audit of what was written refuses.
    module ReconcileFiles
      module_function

      # Writes the plan's composed edge and deletes the edge files it supersedes.
      #
      # @param plan [Reconcile::Plan] a plan with status `:write`
      # @return [Hash{String => String, nil}] each touched path with the text it held, nil if absent
      def write!(plan)
        originals = [plan.write_path, *plan.removals].compact.to_h { |path| [path, read_if_present(path)] }
        File.write(plan.write_path, plan.text) if plan.write_path
        plan.removals.each { |path| FileUtils.rm_f(path) }
        originals
      end

      # Puts each touched file back as `write!` found it.
      #
      # @param originals [Hash{String => String, nil}] what `write!` returned
      def restore!(originals)
        originals.each do |path, text|
          text ? File.write(path, text) : FileUtils.rm_f(path)
        end
      end

      def read_if_present(path) = File.exist?(path) ? File.read(path) : nil
    end
  end
end

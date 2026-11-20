# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # The section of a brief that hands one coder a batch: the lead and each member, in plan
      # order, each with its own detail, and how the batch is built and landed. A work item with no
      # members gets no section.
      module BatchBrief
        # What the coder of a batch does, before the list of its work items.
        STEPS = <<~TEXT.chomp
          Batch: this session builds every work item below, in this order, on the lead's one branch
          and worktree ({work}), and lands them as one train PR. Have one plan covering them all
          reviewed once (work.value={work}); the verdict's findings name each work item. For each
          work item: write its failing spec first, make it green, run its specs, commit it as its
          own commit, then record it: exe/hecks tickets Work.commit! to=<key>
          batch_commit.value=<sha> --wait (the lead's own commit needs no record). A work item the
          batch cannot do (the review says rethink for it, a spec cannot be made green) leaves on
          its own: exe/hecks tickets Work.return! to=<key> "reason.value=<why>" --wait; go on to the
          next. Asked to yield for load, finish and commit the work item you are on, record it, then
          yield the lead; never stop in the middle of one. Each heavy job (a gate run, a spec batch,
          a rust build) takes its slot from the shared heavy-job cap. Report per work item.
        TEXT

        module_function

        # @param item [Plan::Item] the work item a session starts: a lead carries the work items it
        #   builds as `batched`
        # @return [String] the section, empty when the item leads no batch
        def text(item)
          members = Array(item.batched)
          return "" if members.empty?

          ([STEPS] + [item, *members].each_with_index.map { |one, index| line(one, index) }).join("\n")
        end

        # @return [String] one work item of the batch: its place, key, title and detail
        def line(item, index)
          detail = item.detail.to_s.empty? ? "" : "\n   #{item.detail}"
          "#{index + 1}. #{item.key}: #{item.title}#{detail}"
        end
      end
    end
  end
end

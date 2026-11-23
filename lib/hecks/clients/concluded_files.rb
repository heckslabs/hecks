require "hecks/interviews/concluded_record"
require "hecks/sme/discovery_projection"

module Hecks
  module Clients
    # What concluding a client's interview gives to keep in the client's own repo: the record and
    # the bluebook, each a path relative to that repo and its text.
    #
    # Pure: it answers the files and writes nothing. Saving them is the Clients bluebook's
    # `Client.WriteRepoFile`, once per file, which checks the repo is private before each write.
    # Only an interview kept `local` has files here; a `committed` one is Hecks's own and is
    # recorded under `docs/interviews` by `Interviews::ConcludedRecord`, never through this path.
    module ConcludedFiles
      LOCAL = "local".freeze
      # The bluebook's name, read from the first line of its text.
      NAME = /\AHecks\.bluebook "([^"]+)"/

      module_function

      # @param interview [Hash] a concluded interview: `:reference`, `:subject`, `:keeping`,
      #   `:exchanges` and `:points`, each a plain value
      # @return [Hash{String => String}] `interviews/<reference>.md` and `bluebook/<name>.bluebook`
      # @raise [ArgumentError] when the interview is not kept local, or its reference is not one
      #   plain file name
      def call(interview)
        refuse_unless_local(interview)
        bluebook = bluebook_text(interview)
        { "interviews/#{Interviews::ConcludedRecord.file_name(interview[:reference])}.md" =>
                                                                                             Interviews::ConcludedRecord.text(interview),
          "bluebook/#{bluebook[NAME, 1]}.bluebook"                                        => bluebook }
      end

      # @param interview [Hash] a concluded interview
      # @return [String] the bluebook text of its accepted discovery points
      def bluebook_text(interview)
        SME::DiscoveryProjection.text(subject: interview[:subject], points: Array(interview[:points]))
      end

      # @param interview [Hash] a concluded interview
      # @raise [ArgumentError] unless it is kept local
      def refuse_unless_local(interview)
        return if interview[:keeping] == LOCAL

        raise ArgumentError, "only a local interview is saved to a client's repo, not " \
                             "#{interview[:keeping].inspect} (committed records go to docs/interviews)"
      end
    end
  end
end

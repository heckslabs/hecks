module Hecks
  # The module folders of a domain directory (ADR 0163). A folder named for a module holds that
  # module's bluebook beside its name, `deliver/deliver.bluebook`; the bluebooks in them declare
  # the one bluebook the directory's top-level file opens.
  module ModuleFolders
    module_function

    # @param directory [String] a domain directory
    # @return [Array<String>] the bluebook of each module folder directly under `directory`,
    #   sorted by path
    def bluebooks(directory)
      files(directory, ".bluebook")
    end

    def files(directory, extension)
      Dir.glob(File.join(directory, "*", "*#{extension}")).select { |path| module_file?(path, extension) }.sort
    end

    # @param directory [String] a domain directory
    # @return [Array<String>] the directory's own bluebooks, then those of its module folders
    def all(directory)
      Dir.glob(File.join(directory, "*.bluebook")) + bluebooks(directory)
    end

    # Whether a bluebook is named for the folder it sits in.
    # @api private
    def module_file?(path, extension)
      File.basename(path, extension) == File.basename(File.dirname(path))
    end
  end
end

      def initialize
        @fixtures = Hecks::Specializer.load_fixtures(self.class::SHAPE)
      end

      def by_aggregate(name)
        @fixtures.select { |f| f["aggregate"] == name }
      end

      def read_snippet_body(path)
        Hecks::Specializer.read_snippet_body(path)
      end

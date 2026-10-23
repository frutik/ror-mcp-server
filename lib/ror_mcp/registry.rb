# frozen_string_literal: true

module RorMcp
  # Collections in definition order, keyed by [server, collection_name] rather
  # than by class name (PLAN §3): classes in different modules never clash, and
  # two collections claiming one name on a server is an error.
  class Registry
    attr_reader :version

    def initialize
      @collections = []
      @version = 0
      @mutex = Mutex.new
    end

    # Called from Collection.inherited, before the class body runs.
    def track(collection_class)
      @mutex.synchronize do
        @collections << collection_class
        @version += 1
      end
    end

    # Forgets everything (code reload in development re-registers the classes).
    def clear
      @mutex.synchronize do
        @collections.clear
        @version += 1
      end
    end

    # The published collections of one server: { "name" => CollectionClass }.
    def collections_for(server_key)
      server_key = server_key.to_sym
      published.select { |c| c.server_key == server_key }.each_with_object({}) do |collection, by_name|
        name = collection.collection_name
        if by_name.key?(name)
          raise ConfigurationError, "Collection name #{name.inspect} is published twice on server " \
                                    "#{server_key.inspect}: #{by_name[name].name} and #{collection.name}. " \
                                    "Give one of them a distinct collection_name."
        end
        by_name[name] = collection
      end
    end

    # Every published collection: concrete (not abstract!), with a model.
    def published
      @mutex.synchronize { @collections.dup }.select(&:published?)
    end

    # Boot-time checks (no database access) for every server's collections.
    def validate!
      published.each(&:validate!)
      published.map(&:server_key).uniq.each { |key| collections_for(key) }
      true
    end
  end
end

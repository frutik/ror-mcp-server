# frozen_string_literal: true

module RorMcp
  # Collections in definition order, keyed by [server, collection_name] rather
  # than by class name (PLAN §3): classes in different modules never clash, and
  # two collections claiming one name on a server is an error.
  class Registry
    attr_reader :version

    def initialize
      @collections = []
      @toolsets = []
      @version = 0
      @mutex = Mutex.new
    end

    # Called from Toolset.inherited.
    def track_toolset(toolset_class)
      @mutex.synchronize do
        @toolsets << toolset_class
        @version += 1
      end
    end

    # The MCP tools of one server's toolsets. A tool name may appear once per server.
    def toolset_tools_for(server_key)
      server_key = server_key.to_sym
      toolsets = @mutex.synchronize { @toolsets.dup }.select { |t| t.published? && t.server_key == server_key }
      toolsets.each_with_object({}) do |toolset, by_name|
        toolset.tools.each_key do |name|
          if by_name.key?(name)
            raise ConfigurationError, "Tool #{name.inspect} is published twice on server #{server_key.inspect}: " \
                                      "#{by_name[name].name} and #{toolset.name}."
          end
          by_name[name] = toolset
        end
      end.values.uniq.flat_map(&:mcp_tools)
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
        @toolsets.clear
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
      @mutex.synchronize { @toolsets.dup }.select(&:published?).each(&:validate!)
      published.each(&:validate!)
      published.map(&:server_key).uniq.each { |key| collections_for(key) }
      true
    end
  end
end

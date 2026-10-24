# frozen_string_literal: true

module RorMcp
  # What `rake ror_mcp:describe` and `rake ror_mcp:check` print (the counterpart
  # of django-mcp-server's `manage.py mcp_inspect`).
  module Inspector
    module_function

    # Each server: name, mode, instructions, tools with description sizes, and
    # the query tool's collections against the description budget.
    def describe(keys = nil, io: $stdout)
      server_keys(keys).each do |key|
        server = RorMcp.server(key)
        io.puts "#{key}: #{server.name}#{' (stateless)' if server.stateless?}" \
                "#{' (authenticated)' if server.authenticator}"
        io.puts "  instructions: #{server.instructions.inspect}" if server.instructions
        server.tools.each do |tool|
          io.puts "  tool #{tool.name_value} — #{tool.description_value.to_s.length} chars"
        end
        collections = RorMcp.registry.collections_for(key)
        next if collections.empty?

        io.puts "  collections: #{collections.map { |name, c| "#{name} (#{c.model.name})" }.join(', ')}"
        size = Tools::QueryTool.description(collections).length
        budget = RorMcp.configuration.description_budget
        io.puts "  query_data_collections description: #{size} chars" \
                "#{" of a #{budget} budget#{' — OVER' if size > budget}" if budget}"
      end
    end

    # Validates every collection, toolset and server. Returns true when
    # nothing is wrong; prints each problem.
    def check(keys = nil, io: $stdout)
      problems = []
      begin
        RorMcp.registry.validate!
      rescue ConfigurationError => e
        problems << e.message
      end

      server_keys(keys).each do |key|
        collections = RorMcp.registry.collections_for(key)
        collections.each_value do |collection|
          collection.validate_columns!
        rescue ConfigurationError, ActiveRecord::ActiveRecordError => e
          problems << "#{key}: #{e.message}"
        end
        RorMcp.registry.toolset_tools_for(key)
        budget = RorMcp.configuration.description_budget
        if budget && !collections.empty?
          size = Tools::QueryTool.description(collections).length
          problems << "#{key}: query_data_collections description is #{size} chars, over the budget of #{budget}" if size > budget
        end
      rescue ConfigurationError => e
        problems << "#{key}: #{e.message}"
      end

      problems.uniq.each { |problem| io.puts "✗ #{problem}" }
      io.puts "✓ #{server_keys(keys).size} MCP server(s) OK" if problems.empty?
      problems.empty?
    end

    def server_keys(keys)
      keys = Array(keys).compact.map(&:to_sym)
      keys.empty? ? RorMcp.configuration.servers.keys : keys
    end
  end
end

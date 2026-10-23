# frozen_string_literal: true

module RorMcp
  module Pipeline
    # $match → an Arel predicate, following django-mcp-server's _parse_match
    # and the SQL Django generates for the resulting Q objects.
    class Match
      COMPARISONS = { "gt" => :gt, "gte" => :gteq, "lt" => :lt, "lte" => :lteq }.freeze

      # `translate` maps "_id" and "alias.field" to field paths (Lookups#translate).
      def initialize(fields, translate:, extra_filters: [])
        @fields = fields
        @translate = translate
        @extra_filters = extra_filters
      end

      # Returns an Arel node, or nil for an empty condition. `negated` is whether
      # this branch sits under an odd number of negations (Django's current_negated).
      def parse(match, negated: false)
        raise QueryError, "$match must be an object, got #{match.inspect}" unless match.is_a?(Hash)

        # As in django-mcp-server, a logical operator returns at once: other keys
        # in the same object are ignored (PLAN §1A.7).
        return combine(:and, branches(match["$and"], negated)) if match.key?("$and")
        return combine(:or, branches(match["$or"], negated)) if match.key?("$or")
        return negate(combine(:or, branches(match["$nor"], !negated))) if match.key?("$nor")
        raise NotYetSupported.new("$text", "M4") if match.key?("$text")

        nodes = match.flat_map do |field, condition|
          if condition.is_a?(Hash)
            condition.map { |op, value| operator(field, op, value, negated) }
          else
            [lookup(field, "exact", condition, negated)]
          end
        end
        combine(:and, nodes)
      end

      private

      def branches(conditions, negated)
        raise QueryError, "$and, $or and $nor take a list of conditions" unless conditions.is_a?(Array)

        conditions.map { |condition| parse(condition, negated: negated) }
      end

      def operator(field, op, value, negated)
        op = op.to_s
        raise QueryError, "Unknown match key: #{op} : please reveiwe pipeline syntax constraints" unless op.start_with?("$")

        name = op.delete_prefix("$")
        case name
        when "ne" then negate(lookup(field, value.nil? ? "isnull" : "exact", value.nil? || value, !negated))
        when "nin" then negate(lookup(field, "in", value, !negated))
        when "eq" then value.nil? ? lookup(field, "isnull", true, negated) : lookup(field, "exact", value, negated)
        when "gt", "gte", "lt", "lte", "in", "regex" then lookup(field, name, value, negated)
        else
          raise NotYetSupported.new("Extended operator #{op}", "M4") if @extra_filters.include?(name)

          raise QueryError, "Unsupported operator #{op} : please reveiwe pipeline syntax constraints "
        end
      end

      # One Django lookup. Under negation Django adds "col IS NOT NULL" for a
      # nullable column, so NOT (col = v) still matches rows where col is NULL.
      def lookup(field, kind, value, negated)
        resolved = @fields.resolve(@translate.call(field))
        attribute = resolved.attribute
        node =
          case kind
          when "exact" then value.nil? ? attribute.eq(nil) : attribute.eq(value)
          when "isnull" then value ? attribute.eq(nil) : attribute.not_eq(nil)
          when "in"
            raise QueryError, "$in and $nin take a list" unless value.is_a?(Array)

            attribute.in(value)
          when "regex" then Arel::Nodes::InfixOperation.new("REGEXP", attribute, Arel::Nodes.build_quoted(value.to_s))
          else attribute.public_send(COMPARISONS.fetch(kind), value)
          end

        if negated && kind != "isnull" && !value.nil? && resolved.nullable
          node = Arel::Nodes::Grouping.new(node.and(attribute.not_eq(nil)))
        end
        node
      end

      def combine(connector, nodes)
        nodes = nodes.compact
        return nil if nodes.empty?
        return nodes.first if nodes.size == 1

        Arel::Nodes::Grouping.new(connector == :and ? Arel::Nodes::And.new(nodes) : nodes.reduce { |a, b| a.or(b) })
      end

      def negate(node)
        node && Arel::Nodes::Not.new(node)
      end
    end
  end
end

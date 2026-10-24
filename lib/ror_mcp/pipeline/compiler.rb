# frozen_string_literal: true

module RorMcp
  module Pipeline
    # Runs a search pipeline against a relation and returns rows as hashes.
    #
    # `:parity` reproduces django-mcp-server's apply_json_mango_query (PLAN §1A.6):
    # - $limit slices at once; later $match/$sort then fail, as on a sliced QuerySet.
    # - $skip is remembered and applied last, after any $limit ($limit 3, $skip 2 → 1 row).
    # - $sort: direction 1 is ascending, anything else descending; field names untranslated.
    # - $project: truthy values include, "$path" strings map, 0/false are ignored,
    #   dotted output keys nest. Without $project every column comes back.
    #
    # `:fixed` corrects those (PLAN §1B): stages apply in order (a $match after
    # $limit filters the limited rows), $sort takes only 1/-1 and lookup aliases,
    # $project supports exclusion, rows without $project carry only `fields` +
    # computed fields, and default_limit / max_limit apply.
    #
    # Both: $text / $search need every word to match one search field;
    # $group (last stage) gives one row for _id null, the key under the field's
    # name for "$f", keys under "_id" for an object. $sum/$count of 1 is
    # COUNT(*), a documented deviation from Django's Count("id") (PLAN §1B).
    class Compiler
      # Checked in this order, like the if/elif chain in django-mcp-server.
      STAGES = %w[$match $search $sort $skip $limit $project $group $lookup].freeze

      # `collections`: the collections published on the same server.
      def initialize(collection, relation, collections: { collection.collection_name => collection },
                     semantics: RorMcp.configuration.pipeline_semantics, context: nil)
        @collection = collection
        @model = collection.model
        @relation = relation
        @catalog = Catalog.new(collection, collections, semantics: semantics, context: context)
        @fields = Fields.new(@catalog, pseudo: routing_messages)
        @lookups = Lookups.new(@fields)
        @match = Match.new(@fields, translate: @lookups.method(:translate), extra_filters: collection.extra_filters)
        @high = nil   # :parity slice end ([:high])
        @skip = nil   # :parity [skip:] applied last
        @offset = 0   # :fixed window, built in order
        @limit = nil
        @projection = nil
      end

      def rows(pipeline)
        raise QueryError, "search_pipeline must be a list of stages" unless pipeline.is_a?(Array)

        pipeline.each { |stage| @lookups.register(stage["$lookup"]) if stage.is_a?(Hash) && stage.key?("$lookup") }

        pipeline.each_with_index do |stage, index|
          raise QueryError, "Each stage must be an object, got #{stage.inspect}" unless stage.is_a?(Hash)

          case STAGES.find { |name| stage.key?(name) }
          when "$match" then apply_match(stage["$match"])
          when "$search" then apply_search(stage["$search"])
          when "$sort" then apply_sort(stage["$sort"])
          when "$skip" then apply_skip(stage["$skip"])
          when "$limit" then apply_limit(stage["$limit"])
          when "$project" then apply_project(stage["$project"], pipeline[(index + 1)..])
          when "$group"
            unless index == pipeline.size - 1
              raise QueryError, "$group must be the last stage in the pipeline.: please review pipeline syntax constriants."
            end

            return group(stage["$group"])
          when "$lookup" then next # registered above
          else raise QueryError, "Unsupported stage #{PythonRepr.dump(stage)} : please review pipeline syntax constraints"
          end
        end

        fetch
      end

      private

      def fixed?
        @catalog.fixed?
      end

      # --- filtering ------------------------------------------------------------

      def apply_match(condition)
        before_filter
        node =
          if condition.is_a?(Hash) && condition.key?("$text")
            fields = search_fields
            raise QueryError, "$text used but full text search is not supported for this collection." if fields.empty?

            text = condition["$text"]
            raise QueryError, "$text must be an object like {\"$search\": \"words\"}" unless text.is_a?(Hash)

            rest = condition.except("$text")
            combine([text_search(text.fetch("$search", "").to_s, fields), rest.empty? ? nil : @match.parse(rest)])
          else
            @match.parse(condition)
          end
        @relation = @relation.where(node) if node
      end

      def apply_search(spec)
        before_filter
        fields = search_fields
        raise QueryError, "$search used but full text search is not supported for thsi collection." if fields.empty?

        text = spec.is_a?(Hash) ? spec["text"] : nil
        raise QueryError, "$search is limited to {\"text\": {\"query\": \"<keyword>\"}}" unless text.is_a?(Hash) && text.key?("query")

        path = text.fetch("path", fields)
        paths = path.is_a?(String) ? [path] : Array(path)
        raise QueryError, "$search path contains fields that are not allowed for search" unless (paths - fields).empty?

        node = text_search(text["query"].to_s, paths)
        @relation = @relation.where(node) if node
      end

      # :parity: a sliced QuerySet can't be filtered. :fixed: filter the window's rows.
      def before_filter
        if fixed?
          materialize!
        elsif sliced?
          raise QueryError, "Cannot filter a query once a slice has been taken."
        end
      end

      # Each word must match at least one field (OR); all words must match (AND).
      def text_search(value, fields)
        words = value.strip.split.map do |word|
          pattern = "%#{word.gsub(/[\\%_]/) { |c| "\\#{c}" }}%"
          combine(fields.map { |field| @fields.attribute(field).matches(pattern, "\\", false) }, :or)
        end
        combine(words)
      end

      def search_fields
        Schema.text_search_fields(@collection)
      end

      def combine(nodes, connector = :and)
        nodes = nodes.compact
        return nil if nodes.empty?
        return nodes.first if nodes.size == 1

        Arel::Nodes::Grouping.new(connector == :and ? Arel::Nodes::And.new(nodes) : nodes.reduce { |a, b| a.or(b) })
      end

      # --- ordering and pagination ----------------------------------------------

      def apply_sort(spec)
        raise QueryError, "$sort must be an object of field: direction" unless spec.is_a?(Hash)

        if fixed?
          materialize!
        elsif sliced?
          raise QueryError, "Cannot reorder a query once a slice has been taken."
        end

        orders = spec.map do |field, direction|
          if fixed?
            unless [1, -1].include?(direction)
              raise QueryError, "$sort direction for '#{field}' must be 1 (ascending) or -1 (descending), got #{direction.inspect}"
            end

            attribute = @fields.attribute(@lookups.translate(field))
            direction == 1 ? attribute.asc : attribute.desc
          else
            # Django's order_by takes field names as given: no "_id" or alias translation.
            attribute = @fields.attribute(field)
            [1, true].include?(direction) ? attribute.asc : attribute.desc
          end
        end
        @relation = @relation.reorder(*orders)
      end

      def apply_skip(value)
        value = non_negative(value, "$skip")
        return @skip = value unless fixed?

        @offset += value
        @limit = [@limit - value, 0].max if @limit
      end

      def apply_limit(value)
        value = non_negative(value, "$limit")
        if fixed?
          value = [value, max_limit].min if max_limit
          @limit = @limit ? [@limit, value].min : value
        else
          @high = @high ? [@high, value].min : value
        end
      end

      def max_limit
        @collection.max_limit || RorMcp.configuration.max_limit
      end

      def sliced?
        !@high.nil?
      end

      def windowed?
        @offset.positive? || !@limit.nil?
      end

      # :fixed: the rows so far become a subquery under the table's own name, so
      # the next stage works on exactly the window (MongoDB order of stages).
      def materialize!
        return unless windowed?

        inner = @relation.except(:select).select(@model.arel_table[Arel.star])
        inner = inner.joins(*@fields.joins) unless @fields.joins.empty?
        inner = inner.offset(@offset) if @offset.positive?
        inner = inner.limit(@limit) if @limit
        # Orderings on the base table still apply to the subquery's rows.
        orders = @relation.order_values.select do |order|
          order.respond_to?(:expr) && order.expr.respond_to?(:relation) && order.expr.relation.name.to_s == @model.table_name
        end
        @relation = @model.unscoped.from(inner, @model.table_name).reorder(*orders)
        @fields.reset_joins
        @offset = 0
        @limit = nil
      end

      # --- projection and rows --------------------------------------------------

      def apply_project(spec, later_stages)
        if later_stages.any? { |stage| stage.is_a?(Hash) && stage.key?("$group") }
          raise QueryError, "$project cannot appear when pipeline contains $group : please review pipeline syntax constriants."
        end
        raise QueryError, "$project must be an object" unless spec.is_a?(Hash)

        return @projection = exclusion(spec) if fixed? && exclusion?(spec)

        # Output key → internal field name, as Django passes them to values().
        @projection = spec.each_with_object({}) do |(output, value), mapping|
          if value.is_a?(String) && value.start_with?("$")
            mapping[output.to_s] = @lookups.translate(value.delete_prefix("$"))
          elsif python_truthy?(value)
            mapping[output.to_s] = @lookups.translate(output.to_s)
          end
        end
      end

      # :fixed: {"f": 0} excludes; mixing 0 and 1 (other than _id) is an error, as in MongoDB.
      def exclusion?(spec)
        excluded = spec.reject { |key, value| key.to_s == "_id" || python_truthy?(value) }
        included = spec.select { |key, value| key.to_s != "_id" && python_truthy?(value) }
        if excluded.any? && included.any?
          raise QueryError, "$project cannot mix inclusion and exclusion (except for _id): " \
                            "list the fields to keep, or only the fields to drop"
        end
        excluded.any?
      end

      def exclusion(spec)
        dropped = spec.keys.map(&:to_s)
        default_names.reject { |attname, name| dropped.include?(attname) || dropped.include?(name) }
                     .to_h { |attname, _| [attname, attname] }
      end

      # Rows without $project, { output key (attname) → field name }. :parity:
      # every column (Django's values()) plus computed fields. :fixed: the
      # published fields plus computed fields.
      def default_names
        fields = fixed? ? Schema.fields_of(@collection, [], catalog: @catalog) : @fields.columns
        fields.to_h { |f| [f.attname, f.name] }.merge(@collection.computed_fields.keys.to_h { |name| [name, name] })
      end

      def fetch
        relation = window(@relation)
        return [] if relation.nil?

        if @projection.nil? || @projection.empty?
          names = default_names.keys
          return pluck(relation, names).map { |values| names.zip(values).to_h }
        end

        internal = @projection.values.uniq
        pluck(relation, internal).map do |values|
          row = internal.zip(values).to_h
          @projection.each_with_object({}) { |(output, name), out| assign(out, output.split("."), row[name]) }
        end
      end

      def window(relation)
        return fixed_window(relation) if fixed?

        # Django slices: [:high] for $limit, then [skip:] at the end.
        low = @skip || 0
        if @high
          low = [low, @high].min
          return nil if @high - low <= 0

          relation = relation.limit(@high - low)
        end
        low.positive? ? relation.offset(low) : relation
      end

      def fixed_window(relation)
        limit = @limit || RorMcp.configuration.default_limit
        limit = [limit, max_limit].min if limit && max_limit
        return nil if limit&.zero?

        relation = relation.offset(@offset) if @offset.positive?
        limit ? relation.limit(limit) : relation
      end

      # Selects the paths under positional aliases and casts each value with the
      # type of the model that owns its column (pluck would use the base model's).
      def pluck(relation, paths)
        resolved = paths.map { |path| @fields.resolve(path) }
        columns = resolved.each_with_index.map { |r, i| r.attribute.as("c#{i}") }
        select_rows(relation.except(:select).select(*columns)).map do |row|
          row.each_with_index.map { |value, i| read(resolved[i], value) }
        end
      end

      # A column value as Django returns it (decimals quantized to the column's scale).
      def read(resolved, raw)
        value = resolved.type.deserialize(raw)
        column = resolved.field.respond_to?(:column) ? resolved.field.column : nil
        column&.type == :decimal && !value.nil? ? PyDecimal.scaled(value, column.scale) : value
      end

      def select_rows(relation)
        relation = relation.joins(*@fields.joins) unless @fields.joins.empty?
        relation.connection.select_all(relation.arel, "RorMcp").rows
      end

      # --- $group ---------------------------------------------------------------

      def group(spec)
        raise QueryError, "$group must be an object" unless spec.is_a?(Hash)

        materialize! if fixed?
        group_id = spec.fetch("_id") { raise QueryError, "$group requires an _id" }
        aggregates = spec.except("_id").map { |key, aggregate| [key.to_s, aggregate(key, aggregate)] }

        keys = # output key → field path, as django-mcp-server's mapping
          case group_id
          when nil then {}
          when ->(id) { id.is_a?(String) && id.start_with?("$") }
            { group_id.delete_prefix("$") => @lookups.translate(group_id.delete_prefix("$")) }
          when Hash
            group_id.to_h do |key, formula|
              unless formula.is_a?(String) && formula.start_with?("$")
                raise QueryError, "_id in $group only supports null, string or one level object: value of #{key} " \
                                  "must be a string reference to field like $<field>."
              end
              ["_id.#{key}", @lookups.translate(formula.delete_prefix("$"))]
            end
          else
            raise QueryError, "Unsupported _id value in $group. Only allowed : null a \"$field\" or a {\"key\":\"$field\",...} object."
          end

        # aggregate() with nothing to compute is {}.
        return [{}] if group_id.nil? && aggregates.empty?

        rows = run_group(keys.values.uniq, aggregates)
        # aggregate() returns plain keys; values().annotate() rows are remapped and nested.
        return [rows.first.except(*keys.values)] if group_id.nil?

        rows.map do |row|
          out = {}
          aggregates.each { |(key, _)| assign(out, key.split("."), row[key]) }
          keys.each { |output, path| assign(out, output.split("."), row[path]) }
          out
        end
      end

      # [Arel expression, value caster] for one accumulator.
      def aggregate(key, spec)
        unless spec.is_a?(Hash) && spec.size == 1
          raise QueryError, "Aggregation for key #{key} can only be a JSON object of format {\"$<operator>\": \"<parameter>\"}."
        end

        op, arg = spec.first
        reference = arg.is_a?(String) && arg.start_with?("$") ? @fields.resolve(@lookups.translate(arg.delete_prefix("$"))) : nil
        count_all = [1, true].include?(arg)
        case op
        when "$sum"
          return [Arel.star.count, :integer] if count_all
          raise QueryError, "$sum only supports 1 or field references." unless reference

          [reference.attribute.sum, [:sum, reference]]
        when "$avg", "$min", "$max"
          raise QueryError, "#{op} requires a field reference." unless reference

          node = { "$avg" => :average, "$min" => :minimum, "$max" => :maximum }.fetch(op)
          [reference.attribute.public_send(node), [node, reference]]
        when "$count"
          return [Arel.star.count, :integer] if count_all
          raise QueryError, "$count only supports value 1 or a field reference." unless reference

          [reference.attribute.count, :integer]
        else
          raise QueryError, "Unsupported aggregation operator: #{op}"
        end
      end

      def run_group(paths, aggregates)
        relation = @relation
        if @high
          # :parity: aggregating a sliced queryset — Django reads it from a derived table
          # (FROM (SELECT … LIMIT n)); $skip is ignored. MySQL refuses LIMIT inside IN (…).
          inner = @relation.except(:select).select(@model.arel_table[Arel.star]).limit(@high)
          inner = inner.joins(*@fields.joins) unless @fields.joins.empty?
          relation = @model.unscoped.from(inner, @model.table_name)
          @fields.reset_joins
        end

        resolved = paths.map { |path| @fields.resolve(path) }
        selects = resolved.each_with_index.map { |r, i| r.attribute.as("g#{i}") } +
                  aggregates.each_with_index.map { |(_, (node, _)), i| node.as("a#{i}") }
        relation = relation.except(:select, :order).select(*selects)
        # values(f).annotate() with no accumulators adds no GROUP BY: one row per record.
        relation = relation.group(*resolved.map(&:attribute)) unless resolved.empty? || aggregates.empty?

        select_rows(relation).map do |row|
          values = paths.each_with_index.to_h { |path, i| [path, read(resolved[i], row[i])] }
          aggregates.each_with_index { |(key, (_, caster)), i| values[key] = cast_aggregate(caster, row[paths.size + i]) }
          values
        end
      end

      # Values as Django returns them: decimal sums and extremes at the column's
      # scale; decimal averages to 15 significant digits on SQLite (Django's
      # converter), exact elsewhere; other averages as floats.
      def cast_aggregate(caster, value)
        return value.to_i if caster == :integer && !value.nil?
        return value if value.nil? || caster == :integer

        kind, reference = caster
        column = reference.field.respond_to?(:column) ? reference.field.column : nil
        if column&.type == :decimal
          if kind == :average
            sqlite = @model.connection.adapter_name.match?(/sqlite/i)
            return sqlite ? PyDecimal.significant(value) : PyDecimal.exact(value)
          end

          return PyDecimal.scaled(value, column.scale)
        end
        return Float(value) if kind == :average

        reference.type.deserialize(value)
      end

      # --- helpers --------------------------------------------------------------

      def routing_messages
        routing = @collection.routing_field
        return {} unless routing

        { routing.name => "'#{routing.name}' is a routing field: it selects the database and can only be used " \
                          "as an equality at the top level of a $match (e.g. {\"#{routing.name}\": \"<value>\"})" }
      end

      def assign(target, path, value)
        path[0..-2].each { |part| target = (target[part] ||= {}) }
        target[path.last] = value
      end

      def non_negative(value, stage)
        raise QueryError, "#{stage} takes an integer, got #{value.inspect}" unless value.is_a?(Integer)
        raise QueryError, "Negative indexing is not supported." if value.negative?

        value
      end

      def python_truthy?(value)
        ![nil, false, 0, 0.0, "", [], {}].include?(value)
      end
    end
  end
end

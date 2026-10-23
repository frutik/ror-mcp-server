# frozen_string_literal: true

module RorMcp
  module Pipeline
    # Runs a search pipeline against a relation and returns rows as hashes,
    # reproducing django-mcp-server's apply_json_mango_query (`:parity`
    # semantics, PLAN §1A.6):
    #
    # - $limit slices at once; later $match/$sort then fail, as on a sliced QuerySet.
    # - $skip is remembered and applied last, after any $limit ($limit 3, $skip 2 → 1 row).
    # - $sort: direction 1 is ascending, anything else descending; a later $sort replaces it.
    # - $project: truthy values include, "$path" strings map, 0/false are ignored,
    #   dotted output keys nest. Without $project every column comes back.
    # - $text (top level of a $match) / $search: every word must match one search
    #   field, case-insensitively (Django's icontains).
    # - $group (last stage): _id null → one row; "$f" → key under the field's
    #   name; {k: "$f"} → keys under "_id". $sum/$count of 1 is COUNT(*), a
    #   documented deviation (PLAN §1B): Django's Count("id") fails without an id column.
    class Compiler
      # Checked in this order, like the if/elif chain in django-mcp-server.
      STAGES = %w[$match $search $sort $skip $limit $project $group $lookup].freeze

      # `collections`: the collections published on the same server (`$lookup.from`
      # targets, and the computed fields of joined models).
      def initialize(collection, relation, collections: { collection.collection_name => collection })
        @collection = collection
        @model = collection.model
        @relation = relation
        @fields = Fields.new(@model, computed: computed_lookup(collections.values))
        @lookups = Lookups.new(@fields, collections.values.map(&:model))
        @match = Match.new(@fields, translate: @lookups.method(:translate), extra_filters: collection.extra_filters)
        @high = nil
        @skip = nil
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
          when "$skip" then @skip = non_negative(stage["$skip"], "$skip")
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

      def apply_match(condition)
        raise QueryError, "Cannot filter a query once a slice has been taken." if sliced?

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
        raise QueryError, "Cannot filter a query once a slice has been taken." if sliced?

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

      def apply_sort(spec)
        raise QueryError, "Cannot reorder a query once a slice has been taken." if sliced?
        raise QueryError, "$sort must be an object of field: direction" unless spec.is_a?(Hash)

        # Django's order_by takes field names as given: no "_id" or alias translation.
        orders = spec.map do |field, direction|
          attribute = @fields.attribute(field)
          [1, true].include?(direction) ? attribute.asc : attribute.desc
        end
        @relation = @relation.reorder(*orders)
      end

      def apply_limit(value)
        value = non_negative(value, "$limit")
        @high = @high ? [@high, value].min : value
      end

      def apply_project(spec, later_stages)
        if later_stages.any? { |stage| stage.is_a?(Hash) && stage.key?("$group") }
          raise QueryError, "$project cannot appear when pipeline contains $group : please review pipeline syntax constriants."
        end
        raise QueryError, "$project must be an object" unless spec.is_a?(Hash)

        # Output key → internal field name, as Django passes them to values().
        @projection = spec.each_with_object({}) do |(output, value), mapping|
          if value.is_a?(String) && value.start_with?("$")
            mapping[output.to_s] = @lookups.translate(value.delete_prefix("$"))
          elsif python_truthy?(value)
            mapping[output.to_s] = @lookups.translate(output.to_s)
          end
        end
      end

      def fetch
        relation = window(@relation)
        return [] if relation.nil?

        if @projection.nil? || @projection.empty?
          names = @fields.columns.map(&:attname) + @collection.computed_fields.keys
          return pluck(relation, names).map { |values| names.zip(values).to_h }
        end

        internal = @projection.values.uniq
        pluck(relation, internal).map do |values|
          row = internal.zip(values).to_h
          @projection.each_with_object({}) { |(output, name), out| assign(out, output.split("."), row[name]) }
        end
      end

      # Django slices: [:high] for $limit, then [skip:] at the end.
      def window(relation)
        low = @skip || 0
        if @high
          low = [low, @high].min
          return nil if @high - low <= 0

          relation = relation.limit(@high - low)
        end
        low.positive? ? relation.offset(low) : relation
      end

      # Selects the paths under positional aliases and casts each value with the
      # type of the model that owns its column (pluck would use the base model's).
      def pluck(relation, paths)
        resolved = paths.map { |path| @fields.resolve(path) }
        columns = resolved.each_with_index.map { |r, i| r.attribute.as("c#{i}") }
        select_rows(relation.except(:select).select(*columns)).map do |row|
          row.each_with_index.map { |value, i| resolved[i].type.deserialize(value) }
        end
      end

      def select_rows(relation)
        relation = relation.joins(*@fields.joins) unless @fields.joins.empty?
        relation.connection.select_all(relation.arel, "RorMcp").rows
      end

      # --- $group ---------------------------------------------------------------

      def group(spec)
        raise QueryError, "$group must be an object" unless spec.is_a?(Hash)

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
          aggregates.each { |key, _| assign(out, key.split("."), row[key]) }
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
        count_all = arg == 1 || arg == true
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
          # Aggregating a sliced queryset: Django wraps it in a subquery. $skip is ignored, as in Django.
          key = @model.arel_table[@model.primary_key]
          inner = @relation.except(:select).select(key).limit(@high)
          inner = inner.joins(*@fields.joins) unless @fields.joins.empty?
          relation = @model.unscoped.where(key.in(inner.arel))
        end

        resolved = paths.map { |path| @fields.resolve(path) }
        selects = resolved.each_with_index.map { |r, i| r.attribute.as("g#{i}") } +
                  aggregates.each_with_index.map { |(_, (node, _)), i| node.as("a#{i}") }
        relation = relation.except(:select, :order).select(*selects)
        # values(f).annotate() with no accumulators adds no GROUP BY: one row per record.
        relation = relation.group(*resolved.map(&:attribute)) unless resolved.empty? || aggregates.empty?

        select_rows(relation).map do |row|
          values = paths.each_with_index.to_h { |path, i| [path, resolved[i].type.deserialize(row[i])] }
          aggregates.each_with_index { |(key, (_, caster)), i| values[key] = cast_aggregate(caster, row[paths.size + i]) }
          values
        end
      end

      # Values as Django's SQLite converters return them: decimal sums and
      # extremes rounded to the column's scale, decimal averages to 15
      # significant digits, other averages as floats.
      def cast_aggregate(caster, value)
        return value.to_i if caster == :integer && !value.nil?
        return value if value.nil? || caster == :integer

        kind, reference = caster
        column = reference.field.respond_to?(:column) ? reference.field.column : nil
        if column&.type == :decimal
          return Float(format("%.15g", Float(value))) if kind == :average

          return BigDecimal(value.to_s).round(column.scale || 0)
        end
        return Float(value) if kind == :average

        reference.type.deserialize(value)
      end

      def computed_lookup(collections)
        by_model = collections.each_with_object({}) { |c, map| map[c.model] ||= c.computed_fields }
        by_model[@model] = @collection.computed_fields
        ->(model) { by_model.fetch(model, {}) }
      end

      def assign(target, path, value)
        path[0..-2].each { |part| target = (target[part] ||= {}) }
        target[path.last] = value
      end

      def sliced?
        !@high.nil?
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

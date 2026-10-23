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
    class Compiler
      # Checked in this order, like the if/elif chain in django-mcp-server.
      STAGES = %w[$match $search $sort $skip $limit $project $group $lookup].freeze

      # `published_models`: models of the collections on the same server, the
      # only valid `$lookup.from` targets.
      def initialize(collection, relation, published_models: [collection.model])
        @collection = collection
        @model = collection.model
        @relation = relation
        @fields = Fields.new(@model)
        @lookups = Lookups.new(@fields, published_models)
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
          when "$search" then raise NotYetSupported.new("$search", "M4")
          when "$sort" then apply_sort(stage["$sort"])
          when "$skip" then @skip = non_negative(stage["$skip"], "$skip")
          when "$limit" then apply_limit(stage["$limit"])
          when "$project" then apply_project(stage["$project"], pipeline[(index + 1)..])
          when "$group" then raise NotYetSupported.new("$group", "M4")
          when "$lookup" then next # registered above
          else raise QueryError, "Unsupported stage #{PythonRepr.dump(stage)} : please review pipeline syntax constraints"
          end
        end

        fetch
      end

      private

      def apply_match(condition)
        raise QueryError, "Cannot filter a query once a slice has been taken." if sliced?

        node = @match.parse(condition)
        @relation = @relation.where(node) if node
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
          names = @fields.columns.map(&:attname)
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
        relation = relation.except(:select).select(*columns)
        relation = relation.joins(*@fields.joins) unless @fields.joins.empty?
        types = resolved.map { |r| database_type(r.model, r.field.attname) }
        relation.connection.select_all(relation.arel, "RorMcp").rows.map do |row|
          row.each_with_index.map { |value, i| types[i].deserialize(value) }
        end
      end

      # The column's own type: an enum attribute would return its keys, Django returns stored values.
      def database_type(model, column)
        type = model.type_for_attribute(column)
        type.is_a?(ActiveRecord::Enum::EnumType) ? type.subtype : type
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

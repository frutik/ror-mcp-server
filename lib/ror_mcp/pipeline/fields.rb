# frozen_string_literal: true

module RorMcp
  module Pipeline
    # Resolves the field paths a pipeline uses, the way Django resolves them on
    # a queryset: column names, belongs_to names (comparing the foreign key),
    # "pk", computed fields, and "relation__field" paths through belongs_to
    # associations, which add LEFT JOINs under a per-path alias. What a path may
    # reach depends on the Catalog's semantics.
    class Fields
      # A resolved path: the model field, the expression to select or compare
      # (an Arel attribute on its possibly aliased table, or computed SQL), the
      # type that reads its values, and whether NULL is possible.
      Resolved = Struct.new(:field, :model, :attribute, :type, :nullable, keyword_init: true)

      JOIN_ALIAS_PREFIX = "ror_mcp_"

      attr_reader :model, :catalog

      def initialize(catalog, pseudo: {})
        @catalog = catalog
        @model = catalog.base.model
        @pseudo = pseudo # name → message, for routing fields
        @bound = {}      # path → collection a $lookup named for it
        @joins = {}      # path → Arel join node, in the order paths were first used
        @joined = {}     # path → collection its join reads (kept across reset_joins)
        @fields = Hash.new { |cache, klass| cache[klass] = index(Schema.model_fields(klass)) }
      end

      # Every column of the base model, as Django's values() returns them.
      def columns
        Schema.model_fields(@model)
      end

      # A $lookup (`:fixed`) names the collection a path's join uses. One path
      # joins one collection: the join is built once, so a second collection
      # would have its fields checked against rows the first one's scope chose.
      def bind(path, collection)
        current = @bound[path] || @joined[path]
        if current && current != collection
          raise QueryError, "$lookup from '#{collection.collection_name}': '#{path.gsub('__', '.')}' already joins " \
                            "the '#{current.collection_name}' collection, and a reference joins one collection per query"
        end

        @bound[path] = collection
      end

      def resolve(path)
        parts = path.to_s.split("__")
        model = @model
        collection = @catalog.base
        table = @model.arel_table
        nullable = false

        parts[0..-2].each_with_index do |part, index|
          field = field_of(model, collection, part)
          raise unknown(model, collection, part) unless field.reference?

          prefix = parts[0..index].join("__")
          target = @bound[prefix] || (@catalog.fixed? ? @catalog.reference_target(collection, field) : @catalog.collection_for(field.reflection.klass))
          if @catalog.fixed? && target.nil?
            raise QueryError, "'#{part}' points at #{field.reflection.klass.name}, which is not published on this server"
          end
          unless @catalog.same_database?(model, field.reflection.klass)
            raise QueryError, "Cannot join '#{part}': #{model.name} and #{field.reflection.klass.name} live in different databases"
          end

          nullable ||= field.column.null
          table = join(prefix, table, field.reflection, target)
          model = field.reflection.klass
          collection = target
        end

        name = parts.last
        raise QueryError, @pseudo.fetch(name) if @pseudo.key?(name) && parts.size == 1

        computed = @catalog.fixed? ? @catalog.computed(collection) : computed_by_model(model)
        if computed.key?(name) && allowed?(collection, name)
          c = computed[name]
          return Resolved.new(field: c, model: model, attribute: c.expression(table, model.connection), type: c.database_type, nullable: true)
        end

        field = name == "pk" ? primary_key(model) : field_of(model, collection, name)
        Resolved.new(field: field, model: model, attribute: table[field.attname],
                     type: database_type(model, field.attname), nullable: nullable || field.column.null)
      end

      def attribute(path)
        resolve(path).attribute
      end

      # One model field by name or column name (Django's get_field), or nil.
      def find(model, name)
        @fields[model][name.to_s]
      end

      def joins
        @joins.values
      end

      # Forget joins (they now live inside a subquery, `:fixed` pagination).
      def reset_joins
        @joins = {}
      end

      def primary_key(model)
        Schema.model_fields(model).find(&:primary_key) || raise(QueryError, "#{model.name} has no primary key")
      end

      private

      def index(fields)
        fields.to_h { |f| [f.attname, f] }.merge(fields.to_h { |f| [f.name, f] })
      end

      def field_of(model, collection, name)
        field = find(model, name)
        raise unknown(model, collection, name) unless field && allowed?(collection, name)

        field
      end

      def allowed?(collection, name)
        allowed = @catalog.allowed(collection)
        allowed.nil? || allowed.include?(name.to_s)
      end

      def computed_by_model(model)
        @catalog.computed(@catalog.collection_for(model))
      end

      # The column's own type: an enum attribute would return its keys, Django returns stored values.
      def database_type(model, column)
        type = model.type_for_attribute(column)
        type.is_a?(ActiveRecord::Enum::EnumType) ? type.subtype : type
      end

      # LEFT OUTER JOIN of a belongs_to target under an alias per path, so chains
      # and self-references get distinct tables. With a scope (`:fixed`), the
      # join reads the target's scoped rows: LEFT JOIN (SELECT … scope) alias.
      def join(path, parent_table, reflection, collection)
        @joined[path] ||= collection
        scope = @catalog.join_scope(collection)
        alias_name = "#{JOIN_ALIAS_PREFIX}#{path}"
        target = reflection.klass.arel_table.alias(alias_name)
        source = scope ? Arel::Nodes::TableAlias.new(Arel::Nodes::Grouping.new(scope.arel), alias_name) : target
        @joins[path] ||= Arel::Nodes::OuterJoin.new(
          source,
          Arel::Nodes::On.new(parent_table[reflection.foreign_key].eq(target[reflection.association_primary_key])),
        )
        target
      end

      def unknown(model, collection, name)
        allowed = @catalog.allowed(collection)
        names = Schema.model_fields(model).flat_map { |f| [f.name, f.attname] } + @catalog.computed(collection).keys
        names += model.reflect_on_all_associations.reject(&:belongs_to?).map { |r| r.name.to_s } if allowed.nil?
        names &= allowed.to_a if allowed
        QueryError.new("Cannot resolve keyword '#{name}' into field. Choices are: #{names.uniq.sort.join(', ')}")
      end
    end
  end
end

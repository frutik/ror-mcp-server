# frozen_string_literal: true

module RorMcp
  module Pipeline
    # Resolves the field paths a pipeline uses, the way Django resolves them on
    # a queryset: column names, belongs_to names (comparing the foreign key),
    # "pk", and "relation__field" paths through belongs_to associations, which
    # add LEFT JOINs. Every column is reachable, not only `fields`
    # (django-mcp-server behaviour; `:fixed` semantics will narrow this in M6).
    # Computed fields of a published collection resolve too, also through joins.
    class Fields
      # A resolved path: the model field, the expression to select or compare
      # (an Arel attribute on its possibly aliased table, or computed SQL), the
      # type that reads its values, and whether NULL is possible.
      Resolved = Struct.new(:field, :model, :attribute, :type, :nullable, keyword_init: true)

      JOIN_ALIAS_PREFIX = "ror_mcp_"

      attr_reader :model

      # `computed`: model → { name => Collection::Computed } of the collection publishing it.
      def initialize(model, computed: ->(_model) { {} })
        @model = model
        @computed = computed
        @joins = {} # "customer__parent" => Arel join node, in the order paths were first used
        @fields = Hash.new { |cache, klass| cache[klass] = index(Schema.model_fields(klass)) }
      end

      # Every column of the base model, as Django's values() returns them.
      def columns
        Schema.model_fields(@model)
      end

      def resolve(path)
        parts = path.to_s.split("__")
        model = @model
        table = @model.arel_table
        nullable = false

        parts[0..-2].each_with_index do |part, index|
          field = field_of(model, part)
          raise unknown(model, part) unless field.reference?

          nullable ||= field.column.null
          table = join(parts[0..index].join("__"), table, field.reflection)
          model = field.reflection.klass
        end

        name = parts.last
        if (computed = @computed.call(model)[name])
          return Resolved.new(field: computed, model: model, attribute: computed.expression(table, model.connection),
                              type: computed.database_type, nullable: true)
        end

        field = name == "pk" ? primary_key(model) : field_of(model, name)
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

      def primary_key(model)
        Schema.model_fields(model).find(&:primary_key) || raise(QueryError, "#{model.name} has no primary key")
      end

      private

      def index(fields)
        fields.to_h { |f| [f.attname, f] }.merge(fields.to_h { |f| [f.name, f] })
      end

      def field_of(model, name)
        find(model, name) || raise(unknown(model, name))
      end

      # The column's own type: an enum attribute would return its keys, Django returns stored values.
      def database_type(model, column)
        type = model.type_for_attribute(column)
        type.is_a?(ActiveRecord::Enum::EnumType) ? type.subtype : type
      end

      # LEFT OUTER JOIN of a belongs_to target under an alias per path, so chains
      # and self-references (category → parent category) get distinct tables.
      def join(path, parent_table, reflection)
        alias_name = "#{JOIN_ALIAS_PREFIX}#{path}"
        target = reflection.klass.arel_table.alias(alias_name)
        @joins[path] ||= Arel::Nodes::OuterJoin.new(
          target,
          Arel::Nodes::On.new(parent_table[reflection.foreign_key].eq(target[reflection.association_primary_key])),
        )
        target
      end

      def unknown(model, name)
        names = Schema.model_fields(model).flat_map { |f| [f.name, f.attname] } + @computed.call(model).keys
        names += model.reflect_on_all_associations.reject(&:belongs_to?).map { |r| r.name.to_s }
        QueryError.new("Cannot resolve keyword '#{name}' into field. Choices are: #{names.uniq.sort.join(', ')}")
      end
    end
  end
end

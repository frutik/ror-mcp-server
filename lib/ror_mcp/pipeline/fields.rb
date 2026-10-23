# frozen_string_literal: true

module RorMcp
  module Pipeline
    # Resolves the field names a pipeline uses to columns, the way Django
    # resolves them on a queryset: column names, belongs_to names (comparing the
    # foreign key), and "pk". Every column is reachable, not only `fields`
    # (django-mcp-server behaviour; `:fixed` semantics will narrow this in M6).
    class Fields
      def initialize(model)
        @model = model
        @fields = Schema.model_fields(model)
        @by_name = @fields.to_h { |f| [f.name, f] }.merge(@fields.to_h { |f| [f.attname, f] })
      end

      # Every column, as Django's values() returns them: { attname => Field }.
      def columns
        @fields
      end

      # "_id" and "pk" are the primary key; "a.b" is a lookup alias (M3).
      def resolve(name)
        name = name.to_s
        return primary_key if %w[pk _id].include?(name)
        raise NotYetSupported.new("Lookup alias '#{name.split('.').first}' ($lookup)", "M3") if name.include?(".")

        @by_name.fetch(name) do
          raise QueryError, "Cannot resolve keyword '#{name}' into field. Choices are: #{choices.join(', ')}"
        end
      end

      def attribute(name)
        @model.arel_table[resolve(name).attname]
      end

      private

      def primary_key
        @fields.find(&:primary_key) || raise(QueryError, "#{@model.name} has no primary key")
      end

      def choices
        names = @fields.flat_map { |f| [f.name, f.attname] }
        names += @model.reflect_on_all_associations.reject(&:belongs_to?).map { |r| r.name.to_s }
        names.uniq.sort
      end
    end
  end
end

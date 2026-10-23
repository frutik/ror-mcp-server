# frozen_string_literal: true

require "set"

module RorMcp
  module Pipeline
    # What one query may see: the collection queried, the other collections on
    # its server, and the pipeline semantics.
    #
    # `:parity` reproduces django-mcp-server: any column of any related model is
    # reachable, joins ignore the target's scope, `from` is checked against
    # model names only. `:fixed` (PLAN §1B) limits every collection to its
    # `fields` + computed fields, applies the target collection's scope to joins,
    # and resolves references to collections (subclass/STI-aware, or `reference`).
    class Catalog
      attr_reader :base, :semantics, :context

      def initialize(base, collections, semantics:, context: nil)
        @base = base
        @collections = collections.values.uniq
        @semantics = semantics
        @context = context
      end

      def fixed?
        @semantics == :fixed
      end

      def names
        @collections.map(&:collection_name)
      end

      def by_name(name)
        @collections.find { |c| c.collection_name.casecmp?(name.to_s) }
      end

      # Django's allowed_models: lowercase model class names.
      def model_names
        @collections.map { |c| c.model.name.demodulize.downcase }
      end

      # The collection a belongs_to of `collection` points at, or nil.
      def reference_target(collection, field)
        explicit = collection.references[field.name]
        return by_name(explicit) if explicit

        target = field.reflection.klass
        exact = @collections.find { |c| c.model == target }
        return exact if exact || !fixed?

        # STI / subclass publication (django-mcp-server drops these, PLAN §3).
        @collections.find { |c| c.model <= target || target <= c.model }
      end

      # The collection whose fields a model's columns resolve against (parity:
      # the published one with that exact model, if any).
      def collection_for(model)
        return @base if @base.model == model

        @collections.find { |c| c.model == model }
      end

      # Field names a collection exposes under `:fixed`; nil = everything (`:parity`).
      def allowed(collection)
        return nil unless fixed? && collection

        @allowed ||= {}
        @allowed[collection] ||= Set.new(Schema.fields_of(collection, @collections.map(&:model), catalog: self)
                                               .flat_map { |f| [f.name, f.attname] } + collection.computed_fields.keys + ["pk"])
      end

      def computed(collection)
        collection ? collection.computed_fields : {}
      end

      # The target's scope as a join condition (`:fixed` only).
      def join_scope(collection)
        return nil unless fixed? && collection

        relation = collection.new(@context).scope(@context)
        trivial = relation.where_clause.empty? && relation.joins_values.empty? && relation.limit_value.nil?
        trivial ? nil : relation
      end

      def same_database?(a, b)
        config_a = a.connection_db_config
        config_b = b.connection_db_config
        config_a.adapter == config_b.adapter && config_a.database == config_b.database
      rescue ActiveRecord::ConnectionNotEstablished
        true
      end
    end
  end
end

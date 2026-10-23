# frozen_string_literal: true

module RorMcp
  # The MongoDB-style $jsonSchema of a collection, built exactly as
  # django-mcp-server's generate_json_schema builds it (same keys, same key
  # order), from Rails metadata: column types, belongs_to reflections, enums,
  # and descriptions from `describe` or column comments.
  module Schema
    # One model field: a column, or a belongs_to association named after its
    # foreign-key column (Django's ForeignKey `customer` over column `customer_id`).
    Field = Struct.new(:name, :column, :reflection, :primary_key, keyword_init: true) do
      def reference? = !reflection.nil?
      def attname = column.name
      def text? = !reference? && %i[string text].include?(column.type)
    end

    PRIMARY_KEY_DESCRIPTION = "Primary unique identifier for this model"

    # Django field class → bsonType, by Rails column type. Every integer is "int":
    # Django checks IntegerField before BigIntegerField/BigAutoField.
    BSON_TYPES = {
      integer: "int", float: "double", decimal: "double", boolean: "bool",
      datetime: "date", timestamp: "date", date: "date", time: "string",
      json: "object", jsonb: "object", string: "string", text: "string",
    }.freeze

    module_function

    # Every concrete field of a model, in column order.
    def model_fields(model)
      references = model.reflect_on_all_associations(:belongs_to).reject(&:polymorphic?)
                        .to_h { |reflection| [reflection.foreign_key.to_s, reflection] }
      model.columns.map do |column|
        reflection = references[column.name]
        Field.new(name: reflection ? reflection.name.to_s : column.name, column: column,
                  reflection: reflection, primary_key: column.name == model.primary_key)
      end
    end

    # The fields a collection publishes: `fields`, minus `exclude_fields`, minus
    # references nothing on the server can resolve, minus references into
    # another database. Under `:parity` a reference needs the exact class
    # published (django-mcp-server, PLAN §1A.7); under `:fixed` the Catalog
    # resolves it (subclass/STI-aware, or `reference ... to:`).
    def fields_of(collection, published_models = published_models_for(collection), catalog: nil)
      listed = collection.fields
      model_fields(collection.model).select do |field|
        next false unless listed == :all || listed.include?(field.name)
        next false if collection.exclude_fields.include?(field.name)
        next true unless field.reference?

        target = field.reflection.klass
        resolvable = catalog&.fixed? ? !catalog.reference_target(collection, field).nil? : published_models.include?(target)
        resolvable && same_database?(collection.model, target)
      end
    end

    def same_database?(a, b)
      a.connection_db_config.then { |x| [x.adapter, x.database] } == b.connection_db_config.then { |x| [x.adapter, x.database] }
    rescue ActiveRecord::ConnectionNotEstablished
      true
    end

    def published_models_for(collection)
      RorMcp.registry.collections_for(collection.server_key).values.map(&:model)
    end

    # django-mcp-server's get_text_search_fields.
    def text_search_fields(collection)
      return collection.search_fields if collection.search_fields

      listed = collection.fields
      model_fields(collection.model).select { |f| f.text? && (listed == :all || listed.include?(f.name)) }.map(&:name)
    end

    def json_schema(collection, published_models = published_models_for(collection), catalog: nil)
      properties = {}
      required = []
      fields_of(collection, published_models, catalog: catalog).each do |field|
        properties[field.name] = property(collection, field, catalog: catalog)
        required << field.name if required?(field, collection.model)
      end
      collection.computed_fields.each_value { |computed| properties[computed.name] = computed_property(computed) }
      if (routing = collection.routing_field)
        properties[routing.name] = routing_property(routing)
        required << routing.name
      end

      body = { "bsonType" => "object", "properties" => properties }
      body["required"] = required unless required.empty?
      { "description" => model_description(collection), "$jsonSchema" => body }
    end

    def property(collection, field, catalog: nil)
      prop = {}
      prop["description"] = PRIMARY_KEY_DESCRIPTION if field.primary_key
      help = collection.field_descriptions[field.name] || field.column.comment

      if field.reference?
        prop["bsonType"] = "objectId"
        if catalog&.fixed?
          # `:fixed`: name the collection to $lookup into.
          target = catalog.reference_target(collection, field).collection_name
          prop["description"] = "Reference to the '#{target}' collection"
        else
          target = field.reflection.klass.name.demodulize
          prop["description"] = "Reference to #{target}"
        end
        prop["description"] += ": #{help}" if help
        prop["ref"] = target
        return prop
      end

      prop["bsonType"] = BSON_TYPES.fetch(field.column.type, "string")
      prop["description"] = help if help
      choices = choices(collection, field)
      if choices
        prop["enum"] = choices.keys
        listing = choices.map { |value, label| "#{PythonRepr.dump(value)} = #{label}" }.join(", ")
        prop["description"] = prop.key?("description") ? "#{prop['description']} Choices: #{listing}" : "Choices: #{listing}"
      end
      prop
    end

    def routing_property(routing)
      note = "Routing field: required as an equality in $match (selects the database); " \
             "cannot be sorted, projected, grouped or joined."
      { "bsonType" => "string", "description" => routing.doc ? "#{routing.doc}. #{note}" : note }
    end

    def computed_property(computed)
      note = "Computed value, not a stored column or reference."
      { "bsonType" => BSON_TYPES.fetch(computed.type, "string"),
        "description" => computed.doc ? "#{computed.doc}. #{note}" : note }
    end

    # { stored value => label } for a Rails enum, or nil.
    def choices(collection, field)
      mapping = collection.model.defined_enums[field.attname]
      return nil unless mapping

      labels = collection.all_choice_labels.fetch(field.name, {})
      mapping.to_h { |key, value| [value, labels.fetch(value.to_s) { key.to_s.humanize }] }
    end

    # Django: null=False and blank=False. Auto-increment keys are blank; a string
    # field defaulting to "" stands in for blank=True. The default is the model's
    # (column default or `attribute :f, default: ""`): MySQL can't store a
    # default on TEXT columns, Django keeps defaults in Python anyway.
    def required?(field, model = nil)
      column = field.column
      return false if column.null
      return false if field.primary_key && column.type == :integer

      default = model ? model.column_defaults[field.attname] : column.default
      return false if field.text? && default == ""

      true
    end

    # The collection's description, else Django's auto docstring "Model(field, ...)".
    def model_description(collection)
      collection.description&.strip ||
        "#{collection.model.name.demodulize}(#{model_fields(collection.model).map(&:name).join(', ')})"
    end
  end
end

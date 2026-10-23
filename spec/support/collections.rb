# frozen_string_literal: true

# Defines named Collection classes in a clean registry for one example.
module CollectionHelpers
  def define_collection(const_name, &block)
    klass = Class.new(RorMcp::Collection)
    stub_const(const_name, klass)
    klass.class_eval(&block) if block
    klass
  end
end

RSpec.configure do |config|
  config.include CollectionHelpers
  config.before do
    RorMcp.registry.clear
  end
end

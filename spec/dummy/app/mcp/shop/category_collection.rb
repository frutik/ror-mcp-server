# Mirror of the default server in spec/parity/django_app/shop/mcp.py, written
# against the planned RorMcp DSL (PLAN.md §4). Collection names are pinned to
# Django's lowercase model names ("lineitem", not "line_item") so the parity
# corpus addresses the same collections.
module Shop
  class CategoryCollection < RorMcp::Collection
    model Category
    collection_name "category"
    fields :all
    description "A node of the product category tree."
    describe :parent, "Parent category, null for a root"
  end
end

module Analytics
  class AnalyticsTools < RorMcp::Toolset
    server :analytics

    tool :revenue_by_status, description: "Order count and revenue per status."

    def revenue_by_status
      Order.group(:status).order(:status).pluck(:status, Arel.sql("COUNT(*)"), Arel.sql("SUM(total)")).map do |status, n, revenue|
        { status: status, orders: n, revenue: format("%.2f", revenue) }
      end
    end

    tool :line_item_count, description: "Total number of line items."

    def line_item_count
      LineItem.count
    end
  end
end

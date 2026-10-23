# Replaces the shop tables' contents with spec/parity/fixtures/data.json,
# the same rows the Django reference app loads (manage.py load_parity_data).
fixture = JSON.parse(File.read(Rails.root.join("../parity/fixtures/data.json")))
tables = fixture.keys.reject { |t| t.start_with?("_") }

conn = ActiveRecord::Base.connection
# MySQL checks foreign keys row by row, so a self-referencing table (categories) can't be emptied with them on.
conn.disable_referential_integrity do
  ActiveRecord::Base.transaction do
    tables.reverse_each { |t| conn.execute("DELETE FROM #{conn.quote_table_name(t)}") }
    tables.each do |table|
      model = table.classify.constantize
      model.insert_all!(fixture[table], record_timestamps: false)
    end
  end
end

puts "Loaded #{tables.map { |t| "#{t}=#{fixture[t].size}" }.join(', ')}"

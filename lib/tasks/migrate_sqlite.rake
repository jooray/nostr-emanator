namespace :migrate_sqlite do
  desc "Import data from SQLite development database to MariaDB production"
  task import: :environment do
    sqlite_path = Rails.root.join("tmp", "dev.sqlite3")
    unless File.exist?(sqlite_path)
      abort "SQLite file not found at #{sqlite_path}. Copy it there first."
    end

    require "sqlite3"
    sqlite = SQLite3::Database.new(sqlite_path.to_s)
    sqlite.results_as_hash = true

    skip_tables = %w[schema_migrations ar_internal_metadata]

    tables = sqlite.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").map { |r| r["name"] }
    tables -= skip_tables

    tables.each do |table_name|
      puts "Importing #{table_name}..."

      begin
        model = table_name.classify.constantize
      rescue NameError
        puts "  No model for #{table_name}, using raw SQL insert"
        import_raw(sqlite, table_name)
        next
      end

      rows = sqlite.execute("SELECT * FROM #{table_name}")
      columns = rows.first&.keys || []
      next if columns.empty?

      count = 0
      ActiveRecord::Base.transaction do
        rows.each do |row|
          attrs = {}
          columns.each do |col|
            value = row[col]
            column_obj = model.columns_hash[col]
            next unless column_obj

            if column_obj.type == :json || column_obj.type == :jsonb
              attrs[col] = value.is_a?(String) ? (JSON.parse(value) rescue value) : value
            elsif column_obj.type == :boolean
              attrs[col] = ActiveModel::Type::Boolean.new.cast(value)
            elsif column_obj.type == :binary && value.is_a?(String)
              attrs[col] = value
            else
              attrs[col] = value
            end
          end

          record = model.new(attrs)
          record.id = row["id"] if row["id"]
          record.save!(validate: false)
          count += 1
        end
      end

      puts "  Imported #{count} rows"
    end

    puts "Import complete!"
  end

  private

  def import_raw(sqlite, table_name)
    rows = sqlite.execute("SELECT * FROM #{table_name}")
    return if rows.empty?

    columns = rows.first.keys
    count = 0

    ActiveRecord::Base.transaction do
      rows.each do |row|
        values = columns.map { |c| row[c] }
        placeholders = columns.map { "?" }.join(", ")
        col_names = columns.map { |c| "`#{c}`" }.join(", ")

        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql_array(
            ["INSERT INTO `#{table_name}` (#{col_names}) VALUES (#{placeholders})", *values]
          )
        )
        count += 1
      end
    end

    puts "  Imported #{count} rows (raw SQL)"
  end
end

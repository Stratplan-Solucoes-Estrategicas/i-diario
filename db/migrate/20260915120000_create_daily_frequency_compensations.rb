class CreateDailyFrequencyCompensations < ActiveRecord::Migration[5.0]
  def change
    create_table :daily_frequency_compensations do |t|
      t.references :teacher, null: false, foreign_key: true
      t.references :unity, null: false, foreign_key: true
      t.references :classroom, null: false, foreign_key: true
      t.references :discipline, foreign_key: true
      t.references :approved_by, foreign_key: { to_table: :users }

      t.date :compensation_date, null: false
      t.jsonb :lesson_numbers, null: false, default: []
      t.text :reason, null: false
      t.string :status, null: false, default: 'pending'
      t.datetime :approved_at
      t.text :rejection_reason

      t.timestamps
    end
  end
end

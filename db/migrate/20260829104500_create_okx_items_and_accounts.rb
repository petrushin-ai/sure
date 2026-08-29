class CreateOkxItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :okx_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color
      t.string :status, default: "good", null: false
      t.boolean :scheduled_for_deletion, default: false, null: false
      t.boolean :pending_account_setup, default: false, null: false
      t.date :sync_start_date
      t.jsonb :raw_payload
      t.text :api_key, null: false
      t.text :api_secret, null: false
      t.text :passphrase, null: false
      t.timestamps
    end

    add_index :okx_items, :status
    add_index :okx_items, [ :family_id, :api_key ],
              unique: true,
              where: "scheduled_for_deletion = false",
              name: "idx_okx_items_unique_active_api_key_by_family"

    create_table :okx_accounts, id: :uuid do |t|
      t.references :okx_item, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.string :account_type, null: false
      t.string :currency, null: false
      t.decimal :current_balance, precision: 19, scale: 4
      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload
      t.jsonb :extra, default: {}, null: false
      t.timestamps
    end

    add_index :okx_accounts, :account_type
    add_index :okx_accounts, [ :okx_item_id, :account_type ],
              unique: true,
              name: "index_okx_accounts_on_item_and_type"
  end
end

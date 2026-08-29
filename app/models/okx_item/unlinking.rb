module OkxItem::Unlinking
  extend ActiveSupport::Concern

  def unlink_all!(dry_run: false)
    okx_accounts.map do |provider_account|
      links = AccountProvider.where(provider_type: OkxAccount.name, provider_id: provider_account.id).to_a
      result = { provider_account_id: provider_account.id, provider_link_ids: links.map(&:id) }
      next result if dry_run

      ActiveRecord::Base.transaction do
        Holding.where(account_provider_id: links.map(&:id)).update_all(account_provider_id: nil) if links.any?
        links.each(&:destroy!)
      end
      result
    rescue StandardError => e
      result.merge(error: e.message)
    end
  end
end

class OkxAccount::Processor
  include OkxAccount::UsdConverter

  def initialize(okx_account)
    @okx_account = okx_account
  end

  def process
    return unless okx_account.current_account

    OkxAccount::HoldingsProcessor.new(okx_account).process
    amount, stale, rate_date = convert_from_usd(okx_account.current_balance || 0)
    okx_account.current_account.update!(balance: amount, cash_balance: 0, currency: target_currency)
    okx_account.update!(extra: okx_account.extra.to_h.deep_merge(build_stale_extra(stale, rate_date, Date.current)))
  end

  private

    attr_reader :okx_account
    def target_currency
      okx_account.okx_item.family.currency
    end
end

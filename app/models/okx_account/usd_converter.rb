module OkxAccount::UsdConverter
  private

    def convert_from_usd(amount, date: Date.current)
      return [ amount.to_d, false, nil ] if target_currency == "USD"

      rate = ExchangeRate.find_or_fetch_rate(from: "USD", to: target_currency, date: date)
      return [ amount.to_d, true, nil ] unless rate

      converted = Money.new(amount, "USD").exchange_to(target_currency, custom_rate: rate.rate).amount
      [ converted, rate.date != date, rate.date == date ? nil : rate.date ]
    end

    def build_stale_extra(stale, rate_date, target_date)
      metadata = stale ? {
        "stale_rate" => true,
        "rate_date_used" => rate_date&.to_s,
        "rate_target_date" => target_date.to_s
      } : { "stale_rate" => false }
      { "okx" => metadata }
    end
end

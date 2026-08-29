require "test_helper"

class InvestmentStatementTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    # families(:empty) defaults to currency "USD"
    @statement = InvestmentStatement.new(@family, user: nil)
  end

  test "portfolio_value and cash_balance with a single-currency family" do
    create_investment_account(balance: 1000, cash_balance: 100)

    assert_equal 1000, @statement.portfolio_value
    assert_equal 100, @statement.cash_balance
    assert_equal 900, @statement.holdings_value
  end

  test "portfolio_value converts foreign-currency accounts to family currency" do
    create_investment_account(balance: 1921.92, cash_balance: -162, currency: "USD")
    create_investment_account(balance: 1000, cash_balance: 1000, currency: "EUR")

    ExchangeRate.create!(
      from_currency: "EUR",
      to_currency: "USD",
      date: Date.current,
      rate: 1.1
    )

    # 1921.92 + 1000 * 1.1 = 3021.92
    assert_in_delta 3021.92, @statement.portfolio_value, 0.001
    # -162 + 1000 * 1.1 = 938
    assert_in_delta 938, @statement.cash_balance, 0.001
    # 3021.92 - 938 = 2083.92
    assert_in_delta 2083.92, @statement.holdings_value, 0.001
  end

  test "portfolio_value falls back to 1:1 when FX rate is missing" do
    create_investment_account(balance: 1921.92, currency: "USD")
    create_investment_account(balance: 1000, currency: "EUR")

    # No ExchangeRate row → rates_for defaults to 1
    assert_in_delta 2921.92, @statement.portfolio_value, 0.001
  end

  test "current_holdings includes holdings from every investment account regardless of currency" do
    usd_account = create_investment_account(balance: 2100, currency: "USD")
    eur_account = create_investment_account(balance: 2000, currency: "EUR")

    usd_security = Security.create!(ticker: "AAPL", name: "Apple")
    eur_security = Security.create!(ticker: "ASML", name: "ASML")

    Holding.create!(
      account: usd_account, security: usd_security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD"
    )
    Holding.create!(
      account: eur_account, security: eur_security, date: Date.current,
      qty: 4, price: 500, amount: 2000, currency: "EUR"
    )

    assert_equal 2, @statement.current_holdings.count
  end

  test "top_holdings ranks by family-currency value across currencies" do
    usd_account = create_investment_account(balance: 2100, currency: "USD")
    eur_account = create_investment_account(balance: 2000, currency: "EUR")

    usd_security = Security.create!(ticker: "AAPL", name: "Apple")
    eur_security = Security.create!(ticker: "ASML", name: "ASML")

    Holding.create!(
      account: usd_account, security: usd_security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD"
    )
    Holding.create!(
      account: eur_account, security: eur_security, date: Date.current,
      qty: 4, price: 500, amount: 2000, currency: "EUR"
    )

    ExchangeRate.create!(
      from_currency: "EUR", to_currency: "USD",
      date: Date.current, rate: 1.1
    )

    # 2000 EUR = 2200 USD > 2100 USD, so ASML outranks AAPL in family currency
    top = @statement.top_holdings(limit: 2)
    assert_equal %w[ASML AAPL], top.map(&:ticker)
  end

  test "top_holdings aggregates one crypto asset across institutions and exposes account breakdown" do
    binance = create_investment_account(balance: 1200, cash_balance: 200, currency: "USD")
    okx = create_investment_account(balance: 800, cash_balance: 300, currency: "USD")
    binance.update!(name: "Binance (A)")
    okx.update!(name: "OKX (A)")

    binance_eth = Security.create!(ticker: "CRYPTO:ETH", name: "Ethereum", exchange_operating_mic: "XBNC")
    okx_eth = Security.create!(ticker: "CRYPTO:ETH", name: "Ethereum", exchange_operating_mic: "XOKX")

    Holding.create!(
      account: binance, security: binance_eth, date: Date.current,
      qty: 2, price: 500, amount: 1000, currency: "USD"
    )
    Holding.create!(
      account: okx, security: okx_eth, date: Date.current,
      qty: 1, price: 500, amount: 500, currency: "USD"
    )

    top = @statement.top_holdings(limit: 5)

    assert_equal 1, top.size
    assert_equal "CRYPTO:ETH", top.first.ticker
    assert_equal 3, top.first.quantity
    assert_equal 1500, top.first.amount_money.amount
    assert_equal 75, top.first.weight
    assert_equal [ "Binance (A)", "OKX (A)" ], top.first.breakdowns.map { |row| row.account.name }
    assert_equal [ 1000, 500 ], top.first.breakdowns.map { |row| row.amount_money.amount }
  end

  test "top_holdings does not merge non-crypto instruments that only share a ticker" do
    nasdaq = create_investment_account(balance: 1000, currency: "USD")
    london = create_investment_account(balance: 500, currency: "USD")
    nasdaq_security = Security.create!(ticker: "TEST", name: "Test US", exchange_operating_mic: "XNAS")
    london_security = Security.create!(ticker: "TEST", name: "Test UK", exchange_operating_mic: "XLON")

    Holding.create!(account: nasdaq, security: nasdaq_security, date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD")
    Holding.create!(account: london, security: london_security, date: Date.current, qty: 5, price: 100, amount: 500, currency: "USD")

    assert_equal 2, @statement.top_holdings(limit: 5).size
  end

  test "dashboard_positions includes an Investment account with a balance but no holdings" do
    account = create_investment_account(balance: 40_150, cash_balance: 40_150)
    account.update!(name: "Edge Capital")
    crypto = create_investment_account(balance: 10_000, cash_balance: 0)
    security = Security.create!(ticker: "CRYPTO:BTC", name: "Bitcoin")
    Holding.create!(
      account: crypto, security: security, date: Date.current,
      qty: 1, price: 10_000, amount: 10_000, currency: "USD"
    )

    positions = @statement.dashboard_positions(limit: 5)
    account_position = positions.find(&:account_position?)

    assert_equal "Edge Capital", positions.first.ticker
    assert_equal account, account_position.account
    assert_equal 40_150, account_position.amount_money.amount
    assert_in_delta 80.06, account_position.weight, 0.01
  end

  test "dashboard_positions does not duplicate an Investment account that has holdings" do
    account = create_investment_account(balance: 1_000, cash_balance: 0)
    security = Security.create!(ticker: "TESTDASH", name: "Dashboard Security")
    Holding.create!(
      account: account, security: security, date: Date.current,
      qty: 10, price: 100, amount: 1_000, currency: "USD"
    )

    positions = @statement.dashboard_positions(limit: 5)

    assert_equal [ "TESTDASH" ], positions.map(&:ticker)
    assert positions.none?(&:account_position?)
  end

  test "allocation weights sum to 100% with mixed currencies" do
    usd_account = create_investment_account(balance: 2100, currency: "USD")
    eur_account = create_investment_account(balance: 2000, currency: "EUR")

    usd_security = Security.create!(ticker: "AAPL", name: "Apple")
    eur_security = Security.create!(ticker: "ASML", name: "ASML")

    Holding.create!(
      account: usd_account, security: usd_security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD"
    )
    Holding.create!(
      account: eur_account, security: eur_security, date: Date.current,
      qty: 4, price: 500, amount: 2000, currency: "EUR"
    )

    ExchangeRate.create!(
      from_currency: "EUR", to_currency: "USD",
      date: Date.current, rate: 1.1
    )

    allocation = @statement.allocation
    assert_equal 2, allocation.size
    assert_in_delta 100.0, allocation.sum(&:weight), 0.01
    # Every row is labeled in family currency
    assert allocation.all? { |a| a.amount.currency.iso_code == "USD" }
  end

  test "unrealized_gains sums in family currency with mixed-currency holdings" do
    usd_account = create_investment_account(balance: 2100, currency: "USD")
    eur_account = create_investment_account(balance: 2000, currency: "EUR")

    usd_security = Security.create!(ticker: "AAPL", name: "Apple")
    eur_security = Security.create!(ticker: "ASML", name: "ASML")

    Holding.create!(
      account: usd_account, security: usd_security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD",
      cost_basis: 200, cost_basis_locked: true
    )
    Holding.create!(
      account: eur_account, security: eur_security, date: Date.current,
      qty: 4, price: 500, amount: 2000, currency: "EUR",
      cost_basis: 450, cost_basis_locked: true
    )

    ExchangeRate.create!(
      from_currency: "EUR", to_currency: "USD",
      date: Date.current, rate: 1.1
    )

    # AAPL unrealized = 2100 - (10 * 200) = 100 USD
    # ASML unrealized = 2000 - (4 * 450) = 200 EUR → 220 USD @ 1.1
    # Total = 320 USD
    assert_in_delta 320, @statement.unrealized_gains, 0.001
    assert_equal "USD", @statement.unrealized_gains_money.currency.iso_code
  end

  test "unrealized_gains_trend is denominated in family currency" do
    usd_account = create_investment_account(balance: 2100, currency: "USD")
    eur_account = create_investment_account(balance: 2000, currency: "EUR")

    usd_security = Security.create!(ticker: "AAPL", name: "Apple")
    eur_security = Security.create!(ticker: "ASML", name: "ASML")

    Holding.create!(
      account: usd_account, security: usd_security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD",
      cost_basis: 200, cost_basis_locked: true
    )
    Holding.create!(
      account: eur_account, security: eur_security, date: Date.current,
      qty: 4, price: 500, amount: 2000, currency: "EUR",
      cost_basis: 450, cost_basis_locked: true
    )

    ExchangeRate.create!(
      from_currency: "EUR", to_currency: "USD",
      date: Date.current, rate: 1.1
    )

    trend = @statement.unrealized_gains_trend
    assert_equal "USD", trend.current.currency.iso_code
    assert_equal "USD", trend.previous.currency.iso_code
    # current = 2100 USD + (2000 EUR * 1.1) = 4300 USD
    assert_in_delta 4300, trend.current.amount, 0.001
    # previous (cost basis) = (10 * 200) USD + (4 * 450 * 1.1) EUR→USD = 2000 + 1980 = 3980 USD
    assert_in_delta 3980, trend.previous.amount, 0.001
  end

  test "period_return_trend returns nil when no balance data in period" do
    period = Period.custom(start_date: 10.years.ago.to_date, end_date: 9.years.ago.to_date)
    assert_nil @statement.period_return_trend(period: period)
  end

  test "period_return_trend returns nil when start portfolio value is zero" do
    account = create_investment_account(balance: 5000)
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current)
    # Balance only inside the period — nothing strictly before period_start means start_value = 0
    account.balances.create!(
      date: period.date_range.begin,
      balance: 5000,
      currency: @family.currency,
      net_market_flows: 200
    )
    assert_nil @statement.period_return_trend(period: period)
  end

  test "period_return_trend returns Trend with correct absolute and percent return" do
    account = create_investment_account(balance: 10_500)
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current)

    # Pre-period row: start_non_cash_balance drives end_balance (virtual stored column)
    account.balances.create!(
      date: period.date_range.begin - 1.day,
      balance: 10_000,
      currency: @family.currency,
      start_non_cash_balance: 10_000,
      net_market_flows: 0
    )
    # In-period row: 500 of market gains
    account.balances.create!(
      date: period.date_range.begin,
      balance: 10_500,
      currency: @family.currency,
      start_non_cash_balance: 10_000,
      net_market_flows: 500
    )

    trend = @statement.period_return_trend(period: period)
    assert_not_nil trend
    assert_in_delta 500, trend.value.amount, 1
    assert_in_delta 5.0, trend.percent, 0.1
  end

  test "totals skips cache when there are no investment accounts" do
    Rails.cache.expects(:fetch).never

    totals = @statement.totals(period: Period.current_month)

    assert_equal Money.new(0, "USD"), totals.contributions
    assert_equal Money.new(0, "USD"), totals.withdrawals
    assert_equal Money.new(0, "USD"), totals.dividends
    assert_equal Money.new(0, "USD"), totals.interest
    assert_equal 0, totals.trades_count
  end

  test "totals aggregate directly from trade entries" do
    # Use the full current month: a month-to-date period collapses to a single
    # day on the 1st, which would drop the start_date + 1.day trade below.
    period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    shared_user = users(:new_email)
    investment_account = create_investment_account(balance: 500)
    hidden_account = create_investment_account(balance: 500)
    investment_account.share_with!(shared_user, permission: "read_only", include_in_finances: true)

    create_trade(account: investment_account, qty: 2, amount: 120, date: period.start_date)
    create_trade(account: investment_account, qty: -1, amount: -40, date: period.start_date + 1.day)
    create_trade(account: investment_account, qty: 1, amount: 999, date: period.start_date - 1.day)
    create_trade(account: hidden_account, qty: 1, amount: 9999, date: period.start_date)

    statement = InvestmentStatement.new(@family, user: shared_user)
    totals = nil
    queries = capture_sql_queries { totals = statement.totals(period: period) }

    assert_equal Money.new(120, "USD"), totals.contributions
    assert_equal Money.new(40, "USD"), totals.withdrawals
    assert_equal 2, totals.trades_count

    aggregate_queries = queries.grep(/SUM\(CASE WHEN trades\.qty > 0/)
    assert_equal 1, aggregate_queries.size
    assert_includes aggregate_queries.first, "FROM entries JOIN trades"
    assert_includes aggregate_queries.first, "entries.entryable_type = 'Trade'"
    assert_includes aggregate_queries.first, "entries.account_id IN"
    assert_includes aggregate_queries.first, "entries.excluded = false"
    assert_no_match(/FROM \(SELECT "trades"\.\*/, aggregate_queries.first)
    # account_ids is pre-scoped to the family's visible accounts, so the
    # aggregate trusts that input and no longer joins back to accounts.
    assert_no_match(/JOIN accounts/, aggregate_queries.first)
  end

  test "current_holdings memoizes so repeated dashboard-style calls issue a single query" do
    account = create_investment_account(balance: 2100, currency: "USD")
    security = Security.create!(ticker: "AAPL", name: "Apple")

    Holding.create!(
      account: account, security: security, date: Date.current,
      qty: 10, price: 210, amount: 2100, currency: "USD"
    )

    queries = capture_sql_queries do
      @statement.current_holdings
      @statement.top_holdings(limit: 5)
      @statement.allocation
      @statement.day_change
    end

    holdings_queries = queries.grep(/DISTINCT ON \(holdings\.account_id, holdings\.security_id\)/)
    assert_equal 1, holdings_queries.size,
      "current_holdings should only run its DISTINCT ON query once per instance, not once per caller"
  end

  test "current_holdings memoizes the empty (no investment accounts) case too" do
    queries = capture_sql_queries do
      @statement.current_holdings
      @statement.current_holdings
    end

    account_queries = queries.grep(/FROM "accounts"/)
    assert_equal 1, account_queries.size,
      "the investment_accounts lookup backing current_holdings should only run once, even for the empty case"
  end

  private
    def create_investment_account(balance:, cash_balance: 0, currency: "USD")
      @family.accounts.create!(
        name: "Investment #{SecureRandom.hex(3)}",
        balance: balance,
        cash_balance: cash_balance,
        currency: currency,
        accountable: Investment.new
      )
    end

    def create_trade(account:, qty:, amount:, date:)
      account.entries.create!(
        name: "Trade #{SecureRandom.hex(3)}",
        amount: amount,
        date: date,
        currency: account.currency,
        entryable: Trade.new(
          security: Security.create!(ticker: "T#{SecureRandom.hex(8)}", name: "Test Security"),
          qty: qty,
          price: amount.to_d.abs / qty.to_d.abs,
          currency: account.currency
        )
      )
    end
end

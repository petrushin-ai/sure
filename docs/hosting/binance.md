# Binance

Sure connects directly to Binance with a read-only API key. No third-party
aggregator or workflow service is involved.

## Multiple connections and account names

A family can add multiple Binance connections. Each connection has its own
encrypted API key pair and sync lifecycle, so personal, business and Binance
sub-accounts can be imported independently. Use a different Binance API key
for each connection; Sure rejects a duplicate active key within the same
family.

The connection name identifies the credential in provider settings. During
account setup, the imported Sure account name can be edited independently.
Later syncs update balances, holdings and transactions but never overwrite the
chosen account name. Renaming a connection also leaves an already imported
account name unchanged.

Saved credentials are never rendered back into the form. The settings panel
shows an explicit encrypted-credentials indicator instead; blank key fields on
an existing connection mean "keep the saved values", not "credentials are
missing".

Each key produces one combined Sure account containing all supported Binance
balance sources listed below. This avoids double counting between source types
while keeping different API keys in separate Sure accounts.

## Balance coverage

Every sync reads the balance/equity endpoints for:

- Spot;
- Funding (P2P, Pay, Card and Gift Card);
- Cross Margin and every Isolated Margin pair;
- Simple Earn flexible and locked positions;
- BFUSD and RWUSD yield accounts;
- USDⓈ-M Futures and COIN-M Futures;
- Options;
- Portfolio Margin and Portfolio Margin Pro.

Portfolio Margin is an aggregate account. When Binance returns a non-empty
Portfolio Margin balance, Sure uses it instead of the overlapping Cross Margin,
Futures and Options balances. This prevents the same equity from being counted
twice.

Products that are not enabled on the Binance account may reject their balance
endpoint. Sure records each source status in the provider payload and under
**Settings → Debug logs**. A temporary failure never turns the affected source
into a zero balance: its last successful assets are kept until the source can be
read again. The Spot account endpoint is the base credential/IP check. Once it
succeeds, a permission denial from Portfolio Margin, Options or another
optional product is treated as source-specific unavailability instead of an
invalid key for the entire connection. A sync fails outright when the base
credential check fails or every balance source fails.

## Minimum balance

Sure omits a position when its current absolute USD value is less than `$1`.
The boundary is inclusive: a position worth exactly `$1` remains visible.
The cutoff is applied to current holdings only; it does not delete imported
trade history.

If Binance cannot quote an asset in USDT, BUSD or FDUSD during a sync, Sure
uses its last successful quote and marks the price as stale. With no prior
quote, Sure keeps the asset as unpriced instead of assuming it is worth zero
and deleting it. The next sync retries the quote.

## Crypto security identity

Each imported Binance asset is linked to one canonical local security named
`CRYPTO:<asset>`. The connector does not use fuzzy market-data search for this
step because a bare asset such as `BTC` must not be substituted with an
arbitrary fiat pair such as `BTCBRL`. Current holding prices still come from
Binance and are converted into the family's base currency before import.

## Schedule

The native Sidekiq scheduler enqueues every active Binance connection every
four hours, at minute 17. Connections are staggered by 30 seconds, capped at a
10-minute fan-out window, to avoid an API burst when several keys are present.
Manual **Sync now** remains available. The scheduled job uses the same sync
pipeline, connection-scoped idempotency rules and debug logging as a manual
sync. A failure for one key does not prevent the remaining connections from
being scheduled.

## API-key permissions

Use a Binance API key with **Enable Reading** only. Do not enable trading,
withdrawal, or universal-transfer permissions. If IP restrictions are enabled,
allow the Sure server's egress IP.

Only Binance products enabled for the owner of that API key can return data.
Sub-accounts require their own connection unless their balances are exposed to
the key by Binance.

## Diagnostics

The Binance provider payload records:

- the raw response for every selected source;
- `source_status` with `ok` or `unavailable` per source;
- assets carried from a temporarily unavailable source;
- positions excluded by the `$1` cutoff under `dust_omitted`;
- assets with no current or stored USD quote under `unpriced_assets`;
- the configured cutoff under `minimum_holding_usd`;
- the fetch timestamp.

Provider failures are also captured in **Settings → Debug logs** with the
Binance connection id and unavailable source names. API keys and secrets are
never included.

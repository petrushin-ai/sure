# OKX

Sure connects directly to OKX API v5 with a production read-only API key. No
aggregator, n8n workflow or trading permission is involved. The implementation
was checked against the [official OKX API v5 documentation](https://www.okx.com/docs-v5/en/)
last modified on 2026-08-28 and the official
[`okxapi/python-okx`](https://github.com/okxapi/python-okx) client at commit
`fa8d738249286b9b7ff8fed678218701f87bbb86`.

## Credentials and multiple accounts

Every connection stores three encrypted values: API key, secret key and
passphrase. Create the key with **Read** permission only; never grant **Trade**
or **Withdraw**. Restrict it to the application server's egress IP. OKX accepts
up to 20 allowlisted IP addresses per key.

A family can add multiple named connections. Each API key has an independent
sync lifecycle and creates one combined Sure account. Use one key per OKX main
account or sub-account. A connection name and its imported Sure account name
can be edited independently; later syncs never overwrite the imported account
name. A duplicate active API key is rejected within one family.

Secret fields are never rendered back into HTML. The settings panel shows a
saved-and-encrypted indicator; blank fields during an edit preserve the stored
credentials.

## Authentication and resilience

Private requests use OKX's documented signature:

`Base64(HMAC-SHA256(timestamp + method + requestPath + body, secret))`

Sure sends `OK-ACCESS-KEY`, `OK-ACCESS-SIGN`, `OK-ACCESS-TIMESTAMP` and
`OK-ACCESS-PASSPHRASE`. It never sends the simulated-trading header. On OKX
error `50102`, Sure reads `/api/v5/public/time`, corrects the local clock offset
and retries exactly once. Authentication, rate-limit and timestamp errors abort
the sync; a disabled optional product is recorded as unavailable without
invalidating the whole connection. Unexpected HTML and upstream messages are
sanitized before logging.

The Unified Trading balance is the mandatory credential and account-mode
check. A sync cannot report success when this core source fails. When an
optional balance source fails, Sure carries that source's last successful
assets so a temporary permission or product outage cannot delete live
holdings.

## Current balance coverage

One combined account includes non-overlapping current value from:

- Unified Trading (`/api/v5/account/balance`), including Spot, Cross/Isolated
  Margin equity, Futures, perpetual Swaps, Options, Portfolio Margin and the
  equity allocated to trading bots and copy trading;
- Funding (`/api/v5/asset/balances`), including P2P and payment balances;
- Funding non-tradable/delisted assets;
- Simple Earn flexible positions;
- On-chain Earn / DeFi / staking active positions;
- OKUSD;
- Flexible Loan collateral minus outstanding loan amounts;
- active Dual Investment notional (including pending settlement/redemption).

The connector also reads positions and product inventories for diagnostics.
Some official endpoints are explicitly account-wide aggregates and are **not**
added again:

- ETH staking reports total BETH across Trading, Funding and redemption;
- SOL staking reports total OKSOL across Trading, Funding and redemption;
- Stable Rewards reports balance across Trading, Funding and redemption;
- grid/signal/recurring bots and copy-trading positions are already represented
  in Unified Trading equity.

This distinction prevents the double counting that would result from summing
each OKX product screen independently.

## Product and history coverage

Sure reads and stores the global OKX ledgers rather than discovering history
from assets that happen to be held today:

- Account bills (recent and three-month archive);
- Funding bills;
- deposits and withdrawals;
- Convert history;
- fills for Spot, Margin, Swap, Futures and Options.

These ledgers cover cashflows for Simple Earn flexible/fixed, DeFi/Staking,
ETH/SOL/BTC staking, Dual Investment and Lite, flexible/institutional loans,
Shark Fin, Snowball, Seagull, Jumpstart, OKUSD, Stable Rewards/Auto Earn,
trading-bot and copy-trading rewards, P2P, deposits, withdrawals, Convert and
internal transfers. Dedicated product APIs without an independent balance are
diagnostic/history sources, not an extra holding.

OKX's ordinary archive endpoints are retention-limited. Account bills provide
the current 7 days plus the last 3 months. Older Unified-account bills since
2021 require OKX's asynchronous quarterly archive-file workflow and a one-time
backfill; Sure does not pretend the ordinary API returned older data. Retention
and source status remain visible in the encrypted provider payload.

Master-account aggregate products can overlap sub-account keys. For complete
and unambiguous per-subaccount history, connect each subaccount with its own
read-only key. Do not connect the same master-scoped product through several
keys if OKX returns the same aggregate to all of them.

## Minimum balance and pricing

A current position is omitted only when its absolute USD value is strictly
less than `$1`; exactly `$1` remains. This cutoff never removes ledger history.
OKX-provided USD equity is preferred. Other assets are quoted against USDT,
USDC, then USD. A quote failure retains the last good price; without one, the
asset remains explicitly unpriced rather than being treated as zero.

Every holding resolves to the exact local security `CRYPTO:<asset>` with OKX
MIC `XOKX`. Generic fuzzy security search is not used.

## Schedule and diagnostics

The native Sidekiq schedule starts at minute 47 every four hours. Connections
are staggered by 30 seconds with a ten-minute cap, and one failed key does not
block another. Manual sync uses the same pipeline.

The encrypted provider snapshot records per-source status, raw provider data,
diagnostic-only sources, dust omitted by the `$1` rule, unpriced assets,
retention-limited ledgers and fetch timestamps. Debug logs identify the
connection and unavailable source but never include credentials or signed
headers.

## Manual verification

1. Open **Settings → Providers → OKX**.
2. In OKX, create a production API key with **Read** only and the displayed
   server IP in its whitelist.
3. Enter a connection name, API key, secret key and passphrase.
4. Wait for the first sync, then choose **Import account** and set the Sure
   account name.
5. Confirm source diagnostics and compare the combined balance with OKX's
   account overview, accounting for positions below `$1`.

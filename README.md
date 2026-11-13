# 0xda-market Trading Lab

Deterministic, **paper-only** trade replay and research service for the existing 0xda-market ecosystem.

**Runtime:** Ruby 3.3.11, BigDecimal money math, Rack service boundary.
**User interface:** the existing `0xda-market/webapp-core` hosted by `0xda-market/telegram-bot`; Trading Lab does not create a second UI.
**Safety:** no live orders, account trading keys, wallet access, payment balance, exchange execution or production deployment.

## Run tests and CLI

```sh
bundle install
bundle exec ruby -Itest test/replay_test.rb
bundle exec ruby bin/trading-lab replay examples/demo.jsonl
```

The JSONL file contains synthetic data. Records are replayed in collection order, and a signal can fill only on a later tick.

## Private paper replay API

```sh
TRADING_LAB_SERVICE_TOKEN=local-test-only bundle exec rackup -p 9293
curl -X POST http://127.0.0.1:9293/v1/paper/replays \
  -H 'Authorization: Bearer local-test-only' \
  -H 'Content-Type: application/json' \
  -d '{"events":[]}'
```

`POST /v1/paper/replays` expects `{"events":[...],"options":{...}}` and returns `{"status":"ok","data":{...}}`.
Up to 500 events, 64 KiB body, strict ordering, finite positive prices, unique (source, id), no future fills.
Default settings: starting cash 1,000 USDT; notional 100; fee 10 bps; adverse slippage 5 bps; maximum 25% allocation; maximum 30-second delay.
Result includes equity, realized/net PnL, fills, rejections, pending signals and positions; **none is a persisted real balance**.

### Trust boundary

The Telegram bot validates Telegram `initData` and resolves the actor using the existing 0xda-market Core account. Only its trusted server adapter may call Trading Lab with `TRADING_LAB_SERVICE_TOKEN`, never exposed to the browser. The service should bind to a private address; TLS is required if traffic leaves a trusted local network. This service does not authenticate users or place live orders.

The paper engine is isolated from the marketplace checkout, broker liquidity, payments and settlement ledger. Exchange collectors must remain read-only and explicitly user-authorized before running. Former Python Binance collector PR #2 was closed without merge; its read-only collector contract must be ported to Ruby in a separate PR.

## OKX lead trader leaderboard (read-only)

The copytrading research starts from a leaderboard. `OkxLeadTraders` reads the public OKX endpoint
[`GET /api/v5/copytrading/public-lead-traders`](https://www.okx.com/docs-v5/en/#order-book-trading-copy-trading-get-lead-trader-ranks):
no API key, no signature, no order placement.

```sh
bundle exec ruby bin/trading-lab okx-leaders --sort pnl_ratio --min-lead-days 90 --limit 20
```

Options: `sort` (`overview`, `pnl`, `aum`, `win_ratio`, `pnl_ratio`, `current_copy_trader_pnl`), `state` (`all`, `vacancy`),
`min_lead_days` (7, 30, 90, 180), `min_assets`/`max_assets`/`min_aum`/`max_aum` in whole USDT (min ≤ max), `data_version` (14 digits),
`page`, `limit` (1–20). `has_capacity` only compares copy trader counts and does not mean the trader can be copied; eligibility stays unknown. Decimals stay strings; OKX rank order is preserved; the portrait link is dropped.
The client waits at least 0.4 s between requests (documented limit: 5 requests per 2 s per IP) and raises
`RateLimited` on HTTP 429 or OKX code `50011`. PnL and ratios cover the last 90 days, so a leaderboard
rank is survivorship-biased and is not a recommendation to copy anyone.

### Private leaderboard API

```sh
curl 'http://127.0.0.1:9293/v1/leaders/okx?sort=pnl_ratio&min_lead_days=90&limit=20' \
  -H 'Authorization: Bearer local-test-only'
```

`GET /v1/leaders/okx` takes the same options as the CLI as query parameters and returns
`{"status":"ok","data":{...}}` with the normalized page. It uses the same service token as replays.
Invalid or duplicate parameters return 422 before any OKX call; a query over 512 bytes returns 414.
Successful pages are cached in memory for 60 seconds (at most 64 queries) so Mini App traffic stays
under the OKX limit; failures are not cached. OKX rate limiting returns 503 `upstream_rate_limited`,
other upstream failures return 502 `upstream_unavailable`.

© 2026 aiaiaiai · aiaiaiai.org

## Copy a real lead trader (paper)

`POST /v1/paper/copy-replays` with `{"unique_code":"<OKX lead trader code>","options":{...}}` simulates copying that trader's **real** closed positions from the last 3 months. The positions come from the public OKX endpoint [`public-subpositions-history`](https://www.okx.com/docs-v5/en/#order-book-trading-copy-trading-get-lead-trader-lead-position-history), up to 3 pages of 100, cached for 5 minutes per trader.

Model (`CopyReplay`, default `pricing: "quotes"`):
- Every leader position is copied with a fixed, **unlevered** USDT notional (`trade_notional`).
- A signal exists at the leader's open or close time. The follower acts `follower_delay_seconds` later and is filled at the open of the first completed one-minute OKX bar that starts at or after that moment (`CopyQuotes`, public [`history-candles`](https://www.okx.com/docs-v5/en/#order-book-trading-market-data-get-candlesticks-history)). The leader's own fill price is never used, so a fill can lag its signal by the delay plus up to one minute. That quote is then moved against the follower by `slippage_bps`, and `fee_bps` is charged on both sides.
- Open copies are marked to market on every bar between entry and exit. `max_drawdown` is measured on that marked equity, taking each open copy at its worst price of the bar; `max_drawdown_realized` is the old closed-trade figure, kept for comparison. `mark_bar` names the bar size used: one minute when the request budget allows, coarser (up to `4H`) for long holds.
- Opens, closes and marks run in time order. A copy is rejected when free cash or the `max_exposure` share of equity cannot cover it, or when the market has no quote for it (`no_quote`: a delisted instrument, or no bar within 5 minutes). A copy is liquidated when its mark reaches zero, so it loses at most its notional.
- Only the most recent `max_positions` positions are replayed (default 100, at most 300); `positions_available` reports how many OKX returned.
- Defaults: `starting_cash` 1000, `trade_notional` 100, `fee_bps` 10, `slippage_bps` 5, `max_exposure` 1, `follower_delay_seconds` 5 (0–3600).

The result includes:
- equity, net PnL, return, fees and win rate;
- `max_drawdown` (marked) and `max_drawdown_realized`;
- copied, rejected and liquidated counts;
- `baseline_pnl`, the same copies at the leader's prices without costs; `delay_drag`, the part of it lost between the leader's fill and the follower's quote; and `cost_drag`, everything lost to delay, slippage and fees;
- the per-trade list with the leader's prices next to the follower's fills and fill times.

`pricing: "leader"` keeps the earlier optimistic model, which fills at the leader's average prices and has no price path. Use it only to see how much that assumption flatters a trader.

Limits of the model:
- The leader's own leverage is not applied, so the leaderboard's levered returns are not comparable one to one.
- One-minute bars are the finest public history: the fill is the next minute's open, not a tick, and order book depth is not modelled beyond `slippage_bps`.
- Within a bar all open copies are taken at their worst price together, and the bars at the edges of a holding interval count in full. Both can only overstate the drawdown.
- A quoted replay reads up to 120 candle pages from OKX (20 requests per 2 s per IP), so the first call for a trader can take tens of seconds; the result is cached for 5 minutes. When the positions need more pages than that, the call returns 422 and asks for a lower `max_positions`.
- It is paper only, with no orders.

## Research store (PostgreSQL, optional)

Set `TRADING_LAB_DATABASE_URL` to a `postgres://` URL and the service keeps a history of its research in schema `trading_lab`. Without the variable it computes exactly as before and keeps nothing.

- **What is stored.** Every paper replay and every computed copy replay becomes one row in `simulation_runs`: kind, options, the SHA-256 of the exact input, equity, net PnL, drawdown, the paper portfolio it ended with (cash, equity, open positions) and the full result. A request may name an `"experiment"` (`^[a-z0-9][a-z0-9._-]{0,62}$`) to group runs.
- **Append-only.** A trigger rejects `UPDATE` and `DELETE` on runs, so a recorded result cannot be edited afterwards.
- **Migrations.** `db/migrate/*.sql` are applied in name order at boot (`config.ru`) and by `bundle exec ruby bin/trading-lab migrate`. They are serialized by an advisory lock, and a file changed after it was applied stops the migration. A configured database that cannot be reached stops the boot.
- **Responses.** With a store, both replay endpoints add a top-level `run_id`. If the write fails the simulation is still returned, with `"run_id": null`; a request that names an experiment fails with 503 `store_unavailable` instead, because it asked to be recorded.
- **Reading back.** `GET /v1/research/runs?kind=&subject=&experiment=&limit=&before=` lists runs newest first without their full result (`limit` 1–100, `before` pages back by id). `GET /v1/research/runs/<id>` returns one run with its portfolio and result. Both need the service token and return 503 `store_unavailable` without a store.

The store holds paper results only: no balance, order or credential. It uses the `pg` gem, whose platform gem ships its own `libpq`, so the image needs no extra package.

**Where it runs.** Production only, on 0xda-market's own PostgreSQL: the `trading_lab` schema inside Market's `market` database, reached with Core's credentials (see *Production release via infra*). Development has no database and keeps simulating without history: it ships every `master` commit automatically and migrates at boot, so with a database it would migrate production Market data with unreleased code.

## Market data collector (OKX, read-only)

`collect-okx` is a long-running process that records live quotes from the public OKX [`tickers`](https://www.okx.com/docs-v5/en/#order-book-trading-market-data-ws-tickers-channel) WebSocket channel. It logs in nowhere, holds no key and can place no order. It replaces the Python Binance collector of the closed PR #2 and keeps that collector's contract.

```sh
bundle exec ruby bin/trading-lab collect-okx --output data/ticks.jsonl --max-events 10
TRADING_LAB_DATABASE_URL=postgres://... bundle exec ruby bin/trading-lab collect-okx
```

- **Instruments.** Default `BTC-USDT`, `ETH-USDT`, `BTC-USDT-SWAP`, `ETH-USDT-SWAP`; repeat `--instrument` for others (at most 10).
- **Sinks.** `--output` appends JSONL in the paper replay's tick format; with `TRADING_LAB_DATABASE_URL` ticks also go to `trading_lab.market_ticks`. At least one is required.
- **Causal time.** `received_at` is the collector's own clock at receipt. OKX's `ts` is stored separately as `exchange_event_at` and never used as the causal time, because a later simulation could then see a quote before the lab had it. The collector stops if its clock steps backwards.
- **Sampling.** The channel pushes up to ten updates a second. `--min-interval-ms` (default 1000) keeps at most one tick per instrument per interval, always the first one seen. That is about 86,400 rows per instrument per day.
- **Gaps are recorded, not hidden.** Each connection is one row in `market_stream_sessions` with its start, end and end reason. The collector reconnects with backoff (1 s to 30 s) and never backfills, so the time between two sessions is a gap with no observations. A session a crashed process left open is closed at its last tick. `GET /v1/market/sessions?limit=` lists sessions, newest first.
- **Database outage.** Ticks wait in memory (up to 20,000) and are written under their own session once the database is back. Past that the collector exits instead of dropping what it observed.
- **What it is not.** A ticker carries the last trade and the best bid and ask, not every trade and not order book depth. The copy replay still prices from one-minute candles; reading these ticks instead is a separate change.

**Where it runs.** In production only, as the infra workload `market-trading-lab-okx-collector` (the release image with the command `bundle exec ruby bin/trading-lab collect-okx`), writing to the production research database.

## Telegram signal collector and channel accuracy (read-only)

`collect-telegram` watches public Telegram trading channels, keeps every version of their posts and rates their calls against the market that followed.

```sh
TRADING_LAB_DATABASE_URL=postgres://... bundle exec ruby bin/trading-lab collect-telegram --channel some_channel --channel another_one
```

**Source and access.** It reads the public web preview `https://t.me/s/<channel>`, the page Telegram serves to anyone without an account. There is no bot token, phone number or session, so the lab holds no Telegram credential. Private channels and channels that disabled the preview cannot be read. Channels come from `--channel` (repeatable, at most 20) and `TRADING_LAB_TELEGRAM_CHANNELS` (comma-separated). It needs the research store.

**Three layers, all append-only.**
1. *Raw posts* (`telegram_messages`, `telegram_message_revisions`). Each observed state of a post is one immutable revision: `original`, `edit` or `deleted`, with the text, Telegram's own "edited" mark and `observed_at`, the lab's clock when it first saw that state.
2. *Signal candidates* (`telegram_signals`). `SignalParser` reads a revision deterministically: one marked ticker (`#BTC`, `$BTC`, `BTCUSDT`, `BTC/USDT`), one direction, and optional entry, stop and targets, in English, Ukrainian or Russian keywords. An opinion, two tickers, both directions or levels that contradict the direction give no signal. The parser version is stored with each signal.
3. *Outcomes* (`telegram_signal_outcomes`). One final row per rated call.

**How a call is rated** (`SignalRating`).
- A post is judged by the **first** revision that carried a signal. Later edits and deletions are counted (`edited_after`, `deleted_after`) but cannot change the record.
- The entry is the open of the first completed one-minute OKX bar after `observed_at` plus `--delay-seconds` (default 5), the same causal rule as the copy replay.
- The bars are walked for `--horizon-hours` (default 24). The stop or the nearest target, whichever comes first, decides the call; a bar that touches both counts as the stop. With neither, the call `expired` at the horizon's last close.
- `missed`: the price had already passed the stop or the target before the call could be read. `no_quote`: OKX lists no such swap, has no bar for the entry, or its bars stop short of the horizon's end before either level was hit, so the call cannot honestly be called expired.
- A call is rated only once its whole horizon is history, so an outcome never depends on when the rating ran.
- A post first seen more than 5 minutes after it was published (a collector that was down), and every post first found by a backfill, is `late` and never rated.
- `return` is the raw price move in the call's direction, without fees or slippage. It measures whether the channel was right, not what a follower would have earned.

**Reading it.** `GET /v1/signals/telegram/ratings` returns one row per channel: `messages`, `calls`, the outcome counts, `rated`, `pending`, `late`, `edited_after`, `deleted_after`, `average_return` and `accuracy` (targets hit over targets plus stops hit; null until a call resolved either way). `GET /v1/signals/telegram/messages?channel=&limit=` returns a channel's newest posts with every revision, its signal and outcome.

**Limits.**
- An edit is seen at the next poll (`--interval-seconds`, default 60, minimum 15), not when it happened, and only while the post is on the newest page of about 20 posts. Several edits between two polls collapse into one. A deletion is recorded when a known post vanishes from between its neighbours.
- `--backfill-pages N` stores the newest N pages once at start. Posts first found this way are marked `backfilled`: kept as evidence, never rated.
- The parser reads text. A call posted as an image is not seen, and a format it does not know gives no signal rather than a guess.
- All calls are priced on `<BASE>-USDT-SWAP` at OKX, whatever venue the channel meant.
- A small `rated` count says little; the table reports it so the accuracy is never read without it.
- The page markup is Telegram's and can change. A post without a timestamp fails loudly instead of being stored half-read.

**Where it runs.** In production only, next to the market collector, once a channel list is chosen: infra then defines `market-trading-lab-telegram-collector` with `TRADING_LAB_TELEGRAM_CHANNELS`, taking the database URL from Core's envelope like the market collector. Its host must be able to reach `t.me`.

## Production release via infra

The canonical repository is [`0xda-market/trading-lab`](https://github.com/0xda-market/trading-lab), with default branch `master`. Production is **manual-only** and takes two separate steps. This repository holds no infra token.

1. **Publish.** Run *Publish Trading Lab production release* (`deploy-production.yml`, `workflow_dispatch` on `master`) in Environment `production`. It requires a successful push Full CI for the exact SHA, then pushes and attests `ghcr.io/0xda-market/trading-lab:production-<sha>` and prints one activation row per workload. It publishes no secrets.
2. **Activate.** An infra operator runs `aiaiaiai-org/infra` **Deploy workload** with that image for `market-trading-lab`, then for `market-trading-lab-okx-collector`, leaving `secrets_image` empty. Both take their secrets from Core's last delivered envelope, decrypted only inside infra's `edge-prod-1` job.

- **No production secret here.** Trading Lab is part of production Market. Its contracts use `runtime.secretsFrom: market-api-production`: the service receives `TRADING_LAB_SERVICE_TOKEN` and Market's `MARKET_DATABASE_URL` as `TRADING_LAB_DATABASE_URL`, the collector only the URL. The token lives in `0xda-market/core`'s production Environment. No product SSH secrets: `edge-prod-1` owns `SSH_*`. The package is public, so infra pulls it without registry credentials.
- **Database.** Market's own PostgreSQL (`market-postgres-production`), the `market` database, with Market's role. Trading Lab keeps its tables in the `trading_lab` schema and Core keeps its own in `market`, so the two migration histories never meet. Schema separation is not an access boundary: Trading Lab runs with Market's database rights.
- **Order.** The service migrates its schema at boot and refuses to start without its database, so it is activated only after Market's production database and Core's delivery are live.
- Workload: `market-trading-lab`, private Docker alias `market-trading-lab` on `nilx-edge`, port `1927`, no public route. Health check: `GET /health`. Replay and leaderboard require the bearer token.
- A production Telegram bot would hold `TRADING_LAB_TOKEN` (equal to the service token) and `TRADING_LAB_ORIGIN=http://market-trading-lab:1927`. That bot wiring is a separate, reviewed change.

No public DNS, new Telegram credentials, trading API keys or live trading are required.

## Development delivery (automatic)

Infra deploys `market-trading-lab-development` (private `http://market-trading-lab-development:1703`, `edge-prod-1`) on its own; this repository holds no infra token.

- After push Full CI passes on `master`, the `publish-development` job in `ci.yml` (Environment `development`) pushes `ghcr.io/0xda-market/trading-lab:<sha>` and the envelope `:<sha>.secrets`, and attests both.
- The envelope holds only `TRADING_LAB_SERVICE_TOKEN`, encrypted with `age` to `encryptionRecipient` in `aiaiaiai-org/infra` `contracts/servers/edge-prod-1.yaml`.
- One-time setup: in the package settings, under *Manage Actions access*, give `aiaiaiai-org/infra` **Read**.
- To rotate the token, change it in the `development` Environment and re-run Full CI for the `master` head.

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

## Deployment via infra

The canonical repository is [`0x0sky/trading-lab`](https://github.com/0x0sky/trading-lab), transferred from the former `0xda-market` owner. Deployment is **manual-only**, after merging Ruby migration [#3](https://github.com/0x0sky/trading-lab/pull/3) and the infra workload contract.

- Producer Environment `production` secrets: `TRADING_LAB_SERVICE_TOKEN`, `INFRA_DEPLOY_TOKEN`.
- No product SSH secrets; the infra target `edge-prod-1` owns `SSH_*`.
- Workload: `market-trading-lab`, private Docker alias `market-trading-lab`, `nilx-edge`, port `1927`.
- HTTP health: `GET /health`; replay requires a bearer token.
- The producer builds an immutable `ghcr.io/0x0sky/trading-lab@sha256:...` image, obtains the target's public SSH recipient, sends age-encrypted runtime credentials, and waits for the infra health result.
- Its short-lived `github.token` is transmitted only inside the encrypted credential envelope for GHCR pull, never to the runtime container. A failing infra workflow fails the producer deployment.
- The Telegram bot holds `TRADING_LAB_TOKEN` (equal to the service token) and private variable `TRADING_LAB_ORIGIN=http://market-trading-lab:1927` after its production deployment contract is separately reviewed.

No public DNS, new Telegram credentials, trading API keys, database or live trading are required.

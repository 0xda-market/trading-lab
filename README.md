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

## Production release via infra

The canonical repository is [`0xda-market/trading-lab`](https://github.com/0xda-market/trading-lab), with default branch `master`. Production is **manual-only** and takes two separate steps. This repository holds no infra token.

1. **Publish.** Run *Publish Trading Lab production release* (`deploy-production.yml`, `workflow_dispatch` on `master`) in Environment `production`. It requires a successful push Full CI for the exact SHA. It then:
   - pushes and attests `ghcr.io/0xda-market/trading-lab:production-<sha>`;
   - encrypts `TRADING_LAB_SERVICE_TOKEN` with `age` to the `edge-prod-1` `encryptionRecipient` from `aiaiaiai-org/infra`;
   - pushes and attests that envelope as `:production-<sha>.secrets`;
   - prints both digests.
2. **Activate.** An infra operator runs `aiaiaiai-org/infra` **Deploy workload** with `workload=market-trading-lab`, the printed `image` and the printed `secrets_image`. Infra decrypts the envelope only inside its `edge-prod-1` job, then activates the workload and checks its health.

- Producer Environment `production` holds only `TRADING_LAB_SERVICE_TOKEN`. No product SSH secrets: `edge-prod-1` owns `SSH_*`. The package is public, so infra pulls it without registry credentials.
- Workload: `market-trading-lab`, private Docker alias `market-trading-lab` on `nilx-edge`, port `1927`, no public route. Health check: `GET /health`. Replay and leaderboard require the bearer token.
- A production Telegram bot would hold `TRADING_LAB_TOKEN` (equal to the service token) and `TRADING_LAB_ORIGIN=http://market-trading-lab:1927`. That bot wiring is a separate, reviewed change.

No public DNS, new Telegram credentials, trading API keys, database or live trading are required.

## Development delivery (automatic)

Infra deploys `market-trading-lab-development` (private `http://market-trading-lab-development:1703`, `edge-prod-1`) on its own; this repository holds no infra token.

- After push Full CI passes on `master`, the `publish-development` job in `ci.yml` (Environment `development`) pushes `ghcr.io/0xda-market/trading-lab:<sha>` and the envelope `:<sha>.secrets`, and attests both.
- The envelope holds only `TRADING_LAB_SERVICE_TOKEN`, encrypted with `age` to `encryptionRecipient` in `aiaiaiai-org/infra` `contracts/servers/edge-prod-1.yaml`.
- One-time setup: in the package settings, under *Manage Actions access*, give `aiaiaiai-org/infra` **Read**.
- To rotate the token, change it in the `development` Environment and re-run Full CI for the `master` head.

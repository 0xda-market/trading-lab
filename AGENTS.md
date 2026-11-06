# Trading Lab agent rules

- This repo owns only deterministic paper replay, simulation and research; never live orders, exchange credentials, wallet or payment authority.
- Ruby 3.3.11 and BigDecimal are the runtime contract. Keep input/output JSON documents stable across the private service boundary.
- The existing Telegram Mini App in 0xda-market/telegram-bot hosts the user interface using 0xda-market/webapp-core; never introduce a second login or frontend here.
- Strictly preserve collection order, source timestamps, causal fills and explicit risk limits.
- One independent change per feature/ or fix/ branch and draft PR; never commit directly to master.
- Run Full CI before merge. Deployment is separate and always requires explicit approval.
- The unmerged Python Binance collector PR #2 must be ported to Ruby, not merged unchanged.
- Follow MIT LICENSE and the copyright-header policy.

© 2026 aiaiaiai · aiaiaiai.org

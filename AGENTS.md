# Trading Lab agent rules

- This repo owns only deterministic paper replay, simulation and research; never live orders, exchange credentials, wallet or payment authority.
- Ruby 3.3.11 and BigDecimal are the runtime contract. Keep input/output JSON documents stable across the private service boundary.
- The existing Telegram Mini App in 0xda-market/telegram-bot hosts the user interface using 0xda-market/webapp-core; never introduce a second login or frontend here.
- Strictly preserve collection order, source timestamps, causal fills and explicit risk limits.
- One independent change per feature/ or fix/ branch and draft PR; never commit directly to master.
- Run Full CI before merge. Deployment is separate and always requires explicit approval.
- The unmerged Python Binance collector PR #2 must be ported to Ruby, not merged unchanged.
- Follow MIT LICENSE and the copyright-header policy.

## Agent identity and attribution

Applies to every coding agent and client, whatever its product or vendor —
for example Kimi, Grok, Claude Code, Codex or any other — whenever it writes
to GitHub on behalf of a person. The list of tools is open; nothing here
depends on a particular one.

Roles:

- **Human owner** — the person who asked for the change and is accountable
  for it.
- **Owner's bot** — the human owner's dedicated Git/GitHub bot identity,
  configured in the execution environment. It authors agent commits.
- **Tool** — the agent client actually doing the work, named as the product
  calls itself.

| Action       | Comes from                               | Signature                          |
|--------------|------------------------------------------|------------------------------------|
| Commit       | author and committer: owner's bot        | `Assisted-by: <Tool>` trailer      |
| Pull request | human owner's credentials                | description names tool and bot     |
| Review       | the reviewing tool                       | `Review by <Tool>` header          |
| Merge        | human owner's credentials, preferably    | trailers from commits preserved    |

## Commits

- Author and committer are the owner's bot identity configured for the
  environment. Never use the human owner's name or email, and never a tool
  vendor's noreply address, as the commit author.
- Every agent commit ends with `Assisted-by: <Tool>` naming the tool that
  actually ran, one line per tool. The model may follow in parentheses:
  `Assisted-by: <Tool> (<model>)`, e.g. `Assisted-by: Kimi` or
  `Assisted-by: Grok (<model>)`.
- `Co-authored-by` names people or accounts that materially wrote part of
  the change. Keep the tool vendor's own trailer when the tool provides one,
  e.g. `Co-authored-by: <Tool> <vendor noreply address>`: GitHub shows it as a
  co-author, while `Assisted-by` stays plain text. Use both; neither replaces
  the other.
- If no bot identity is configured, stop and ask. Do not fall back to the
  human owner's identity.

## Pull requests

- Try to open the pull request with the human owner's credentials — the
  GitHub connection the person gave the tool.
- The description says the change was prepared with `<Tool>` and that the
  commits are authored by the owner's bot. Never present agent work as typed
  by the person.
- If only bot credentials are available, open it from the bot and name the
  human owner in the description.

## Reviews

- Reviews and review comments are signed by the reviewing tool: the first
  line reads `**Review by <Tool>**`. A tool reviewing another tool's work
  names both.
- Post the review as a comment review. Do not approve with the human owner's
  credentials: GitHub does not count an approval of your own pull request,
  and it would present the agent's verdict as the person's approval. Never
  dismiss or circumvent a required review.

## Merge

- The final merge is preferably made with the credentials of the human who
  created the pull request. When the agent works through that person's
  connection, it merges under the merge rules below. Otherwise it leaves the
  pull request ready and reports that it waits for the human merge.
- A squash or merge commit keeps every `Assisted-by` and `Co-authored-by`
  trailer from the branch commits.

## Check before the first write

Verify the authenticated GitHub account, the local Git author and committer,
and that both match the roles above. Recheck when credentials or the
environment change. On a mismatch, stop and report it instead of switching
accounts silently.

© 2026 aiaiaiai · aiaiaiai.org

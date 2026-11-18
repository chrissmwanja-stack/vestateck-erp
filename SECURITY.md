# Security policy

VestaPortal is proprietary software that is live in production, and this
repository is public for visibility only (see `LICENSE`).

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Report it privately through GitHub: **Security tab, then "Report a
vulnerability"** (private vulnerability reporting).

Include what you found, how to reproduce it, and which part of the platform it
affects (web app, a Supabase table, RPC or policy, an edge function, or an
`/api` route). Do not access, change or download other people's data while
testing, and do not run load or denial-of-service tests against the live
service.

You can expect an acknowledgement within a few working days. This is a small
team, so there is no bug bounty.

## Scope

In scope: the web app, the Supabase schema (RLS policies and `SECURITY
DEFINER` functions), the edge functions in `supabase/functions`, and the
`/api` routes.

Out of scope: social engineering, physical attacks, and findings that need an
already compromised device or account.

## What the repository contains

No real customer data and no secrets are meant to be in this repository. The
Supabase anon key in `.env.example` files is a placeholder. If you find a
real secret or real personal data in the code or in the git history, please
report it through the channel above.

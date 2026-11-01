# Stall POS

Mobile-first shared sales app for the November 2026 exhibition. Sales are stored in Supabase in whole rupees, with server-side price and discount calculations, India-time reports, an audit trail, live updates, PWA installation and optional Web Push.

## Local setup

1. Use Node.js 20 or newer and install dependencies with `npm install`.
2. Copy `.env.example` to `.env.local` and fill in the Supabase project URL, anon key and service-role key. The service-role key stays server-side and must never be prefixed with `NEXT_PUBLIC_`.
3. Apply `supabase/migrations/001_initial.sql` in the Supabase SQL Editor (or with the Supabase CLI). It creates the products, sale and audit tables, RPCs, RLS policies, realtime publication and daily-summary setting.
4. In Supabase Authentication → Sign In / Providers, enable **Anonymous sign-ins**. The app creates an anonymous session on each phone; there is no login screen or shared password. Supabase recommends CAPTCHA/Turnstile to limit anonymous-account abuse; enable it only if you accept an initial challenge on devices. The database grants the same shared POS access to authenticated sessions, and no operator identity is displayed or attached to sales.
5. Run `npm run dev` and open the shown LAN address on phones connected to the same network. For push, use HTTPS (localhost is also accepted by browsers).

## Supabase behavior

The app uses Supabase anonymous sign-in silently in the background so Row Level Security remains enabled without showing a login page. Each device gets an anonymous session; all sessions share the same sales and settings. Enable anonymous sign-ins in the Supabase Auth provider settings before use.

- The `create_sale` and `update_sale` RPCs read the current product price and calculate gross, discount and final amounts in PostgreSQL. Each sale snapshots the product name and unit price. Monetary fields use integer rupees.
- Sale creation carries a unique idempotency UUID; retries with the same key return the saved row rather than creating a second sale.
- Sales have realtime publication enabled. The app listens for database changes and refreshes the live views; it also refreshes periodically as a recovery path.
- Every sale insert, edit or deletion writes old/new row data to `sale_audit`. The app can read that history; the SQL trigger writes it.
- Configure future default prices by updating `products.price_rupees` in Supabase. Past sales keep their original unit price.

## Web Push setup

Generate VAPID keys, for example with `npx web-push generate-vapid-keys`. Set `VAPID_PUBLIC_KEY`, `NEXT_PUBLIC_VAPID_PUBLIC_KEY` (same public value), `VAPID_PRIVATE_KEY`, and `VAPID_SUBJECT` in local and Vercel environment variables. Keep the private key server-only. The `push_subscriptions` table stores subscribed device endpoints. Devices opt in from Dashboard → Team notifications. New-sale push is sent by the server route after a committed sale. The daily summary cron checks the configured IST time (default 21:00) every 15 minutes and sends once per day to active subscriptions.

The configured Vercel schedule runs every 15 minutes and requires a Vercel plan that allows that frequency (Pro or Enterprise). Vercel Hobby cron runs at most once daily with up to 59 minutes of timing variance, so it cannot honor a configurable daily time reliably. For Hobby, remove the `crons` entry or change it to a once-daily schedule and accept the timing limit, or use an external scheduler every 15 minutes. The cron route is protected by `CRON_SECRET`; external requests must send `Authorization: Bearer <CRON_SECRET>`.

## Deploy to Vercel

1. Push this project to a Git repository and import it in Vercel.
2. Add all values from `.env.example` in Vercel Project Settings → Environment Variables. Set the Supabase values for Production and Preview only if each environment has the intended shared database.
3. Deploy. The `vercel.json` schedule calls the daily-summary endpoint; configure the cron secret above.
4. Open the deployed HTTPS URL. The app connects automatically without a login screen. Share the URL with the team.

## Install on phones

- **iPhone:** Open the HTTPS site in Safari, tap Share → Add to Home Screen. Open the installed app, then enable notifications in Dashboard. Web Push on iOS requires iOS 16.4 or later and an installed Home Screen web app.
- **Android:** Open the HTTPS site in Chrome and choose Install app / Add to Home screen. Enable notifications in Dashboard and allow the browser prompt.

## Daily workflow and export

The app opens on Sell. Tap a product, optionally adjust quantity or add a discount, then tap Cash or UPI. Discounts are optional and support per-unit, transaction-total and final-price entry. Reports lets the team select a date, view daily and exhibition totals through 7 November 2026, share a closing summary and download all transactions as CSV.

Corrections are made from Transactions → transaction detail → Edit transaction. Delete and Undo operations are also written to the audit table. Keep the service-role key private. Anonymous sign-in removes the login gate: anyone who obtains the app URL can access and change the shared sales data. Only share the URL with the team. If the URL must be public, add a shared access code or other gate before storing real sales.

## Operational limits

An active internet connection is required to record sales; offline sales are disabled and visibly marked. A sale is only shown as saved after Supabase confirms the atomic RPC. The app does not queue unsaved sales. Browser/OS push support and notification permission are required for notifications. The current export is CSV (Excel opens it); XLSX generation is not included.

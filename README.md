# SSC Intramurals 2026 Daily Attendance Portal

A static web app using Supabase Auth + Postgres for authorized SSC officers. The portal supports name search and student selection, date-specific schedules, and four separate attendance actions per student per day: Morning Time In, Morning Time Out, Afternoon Time In, and Afternoon Time Out.

## Confirmed attendance behavior

- **Timezone:** Philippine Time (PHT), `Asia/Manila` (UTC+8).
- **Display format:** 12-hour clock with AM/PM everywhere times are shown.
- **Daily schedule:** Each calendar date has its own configurable morning and afternoon scheduled times.
- **Attendance records:** One row per student per date, with four independent timestamp fields.
- **Dashboard:** The roster includes all active participants across departments. Search and filters help officers find the right student; pagination keeps the browser responsive. CSV export includes every active participant for the selected date, including students with no attendance entries.
- **Duplicate prevention:** Each of the four attendance actions can be recorded only once per student per day. Attendance actions are enabled only when the selected date is the current Philippine date; other dates are view/export only.
- **Internal system IDs:** `participants.id` is the stable internal UUID. It is not an official student number. Names alone are never used as a unique key.
- **Legacy data:** Existing attendance rows and timestamps are preserved. Historical rows are not automatically guessed to be morning or afternoon attendance.
- **Offline mode:** The app shell, authorized roster, and selected-date snapshot are cached on the device after an authorized online load. If the network drops, attendance actions are queued locally with their captured timestamps and synced when internet returns. Queue conflicts are flagged instead of silently overwriting an existing record.
- **Device requirement:** Offline mode is designed for an approved, access-controlled device. The local roster and queue are stored in that browser profile. Do not use public/shared devices, clear site data, or uninstall the browser while unsynced records remain.
- **Clock and audit limitation:** Offline timestamps depend on the device clock and are not as independently verifiable as server timestamps. The server accepts queued events only when the captured PHT date matches the selected date and the timestamp is within the seven-day sync window. Review conflicts or questionable timestamps manually.

The schedule defaults shown in the UI (7:00 AM, 11:30 AM, 1:00 PM, and 4:30 PM) are examples until the admin saves them for a selected date. They do not automatically open/close attendance actions; the timestamps saved when officers click the action buttons are the actual attendance times.

## 1. Configure the app

`app.js` is preconfigured with the Supabase project URL and publishable key. A publishable/anon key is intended for browser use. **Never put a `service_role` key or secret key in browser code.** Keep Row Level Security (RLS) enabled.

## 2. Update the Supabase database

If this is a new installation, review and run `schema.sql` in Supabase SQL Editor.

If you are updating the existing portal, **run `upgrade-daily-attendance.sql`** in Supabase SQL Editor. It adds the four timestamp columns, the per-date schedule table, and the guarded attendance RPC without deleting participant or attendance rows. Review the migration and test it using an authorized test account before official use.

The browser uses `public.record_attendance_action(...)` for online writes and `public.sync_offline_attendance_action(...)` to sync queued offline writes. Both require an active SSC officer and prevent duplicate actions. Offline sync validates the captured timestamp against the selected Philippine date and a seven-day sync window. Review the appended offline-sync SQL carefully before running it.

## 3. Create authorized officer account(s)

In Supabase Dashboard → Authentication → Users, add an account for each approved officer. Then run a separate statement for each officer, replacing the UUID and display name with the real values:

```sql
insert into public.ssc_officers (user_id, display_name, active)
values ('AUTH_USER_UUID_HERE', 'SSC Attendance Officer', true);
```

Get the UUID from the Auth Users table. Do not authorize every signed-up user. Keep public sign-ups disabled if accounts are provisioned by an administrator.

## 4. Register Official 2026 SSC Officers
Run `add-ssc-officers-2026.sql` in the Supabase SQL Editor. This script:
- Adds the `position` column to `public.participants`.
- Upserts the 13 official SSC Executive Officers and Department Senators with their formal titles (President, Vice President, Secretary, Treasurer, Auditor, P.I.O., Business Managers, and Senators).
- Preserves existing attendance records and UUIDs for matched participants.

## 5. Import the full enrolled-student roster

The prepared import file `SSC_Intramurals_2026_Import_WITH_SYSTEM_IDS.csv` and cleaned workbook `SSC_Intramurals_2026_Cleaned_All_Students.xlsx` are provided as separate downloads with this update. Keep roster files outside the publicly deployed website folder. It contains the 1,170 cleaned roster rows with stable internal UUIDs. The UUIDs are **not official student numbers**; the source masterlist did not provide official IDs. The optional `student_number` column is blank.

1. Review the cleaned roster and the internal IDs. Keep the CSV and Excel workbook private.
2. In Supabase SQL Editor, run `import-students.sql` after reviewing it. The staging table is for Supabase Dashboard/admin use only and has no browser-facing policies.
3. Use Table Editor to import the CSV into `public.ssc_participant_import`. Map `id`, `student_number`, `full_name`, `department`, `year_level`, `participant_type`, and `active`.
4. Run the review queries commented in `import-students.sql`. Confirm 1,170 rows, 1,170 distinct non-null IDs, no blank names/departments, and correct department labels.
5. Only after reviewing, run `apply-student-import.sql`. It matches on the generated internal UUID and preserves participant IDs and attendance history when the same file is re-imported.
6. Do not regenerate the IDs or import a different roster under new IDs after attendance begins. The same person may appear twice if an older roster was already imported under different IDs; reconcile such records manually with the roster owner instead of matching names automatically.
7. Do not truncate `participants` or `attendance`. The import does not delete participants missing from a later roster.

## 5. Test before launch

- Sign in as an active officer.
- Select today's date and save a schedule using 12-hour AM/PM times.
- Search for a test student and verify the correct department/year context before recording attendance.
- Record each of the four actions and confirm the displayed times are Philippine Time.
- Attempt each same action a second time; it should be rejected. Other session actions for the same student should still be available.
- Select a different date and verify the records change to that date and attendance actions are disabled.
- Export CSV and confirm all active students appear, including those without attendance records.
- Sign in with an account not in `ssc_officers`; it must not be able to read roster, attendance, or schedule data.
- While online, load the roster and save the schedule for today. Confirm the app-shell and Supabase SDK have been cached.
- Disconnect the network, record a test student action, and confirm the dashboard shows an offline pending count.
- Reconnect and confirm the queued entry syncs with the original captured timestamp.
- Test duplicate/conflict handling and confirm no existing record is silently overwritten.
- Confirm RLS is enabled and policies match school privacy requirements.

## 6. Publish

Deploy this folder as a static site using an HTTPS static hosting provider. The app loads Supabase JS v2 from jsDelivr and registers a service worker to cache the app shell and SDK after a successful online visit. Offline operation requires the site to be hosted over HTTPS (or localhost) and the officer to have signed in and loaded the roster online at least once on that device. A roster and selected-date snapshot are cached in browser local storage, and queued actions stay on that device until they sync. Restrict the site and roster access according to school policy.

## Data model

- `ssc_officers`: authorized users and active status.
- `participants`: enrolled-student directory; `id` is the stable internal UUID, `student_number` is optional, and `year_level` is retained when available.
- `attendance`: one row per participant/date, containing four independent attendance timestamps and legacy audit fields.
- `attendance_day_settings`: one schedule per date, with morning and afternoon scheduled time-in/time-out values.
- `offline_attendance_sync_events`: idempotency/audit records for offline attendance events that have been synced.

## Important limitations

- This update prepares the website code, SQL migration, and import files. It does **not** run SQL in your Supabase project, import the roster, create officer accounts, or deploy the site. Those steps must be completed in the Supabase/hosting dashboards.
- A saved schedule is the expected schedule for the day; the actual time recorded is the database timestamp when an officer records an action.
- Historical legacy check-ins remain intact, but they do not have inferred morning/afternoon values. Do not assume old records represent a particular session.


## Optional attendance-entry deletion
To enable the per-slot Delete buttons for erroneous time-ins/time-outs, run `attendance-delete-action.sql` once in the Supabase SQL Editor as the project owner. Then deploy/replace the updated `index.html`, `app.js`, and `styles.css` from this folder. Deletion requires an internet connection and an authorized active officer. It deletes only the selected attendance slot, preserves other slots and the student roster, and uses a cancellation marker to prevent stale offline sync from restoring the deleted slot. Test with a non-critical test record first.


## Attendance deletion troubleshooting (updated 2026-10-24)

- The roster now shows a **Delete** control in every attendance slot. It is disabled when that slot has no recorded timestamp and enabled only when a timestamp exists.
- Deletion requires an internet connection and an authorized active SSC officer. It asks for confirmation and removes only the selected time-in/time-out slot.
- After running `attendance-delete-action.sql` successfully in Supabase SQL Editor, reopen the updated `index.html` from this folder or redeploy the whole folder. The HTML asset version and service-worker cache version were bumped to reduce stale-file issues.
- If Delete reports an error, do not manually delete database rows. Read the exact error toast and verify that `attendance-delete-action.sql` ran against this same Supabase project and that the signed-in user is an active row in `public.ssc_officers`.
- The UI checks the RPC's returned boolean and will not claim success unless the database confirms the selected slot was deleted.


## Student-facing attendance portal (new)

- Open `student.html` for the student kiosk interface; `index.html` remains the authorized SSC admin dashboard.
- Student workflow: search by name (minimum 2 characters), select the matching student, then use only the action currently enabled by the admin.
- The admin toggles the four actions in the schedule panel and clicks **Save schedule**. Controls default to closed until an authorized admin explicitly enables them.
- Before using the student portal, run `student-portal-migration.sql` once in the Supabase SQL Editor. It adds action toggles and public RPC functions without deleting existing attendance rows.
- The student page polls the public control RPC every 15 seconds and refreshes when the tab regains focus. The database independently checks that the action is enabled at submission time.
- Atomic conditional database updates prevent duplicate records for the same student/action even when multiple devices submit at once. Six or more devices should be fine under normal event traffic; run a controlled load test before relying on peak-event usage.

### Important kiosk security note

This workflow intentionally has no student login: anyone who can access the kiosk page can search a name and attempt to record attendance for that name. Use supervised, staff-controlled devices or an on-site kiosk, and understand this identity limitation before official deployment. The student page does not expose a service-role key; its public database functions return only matching names and limited attendance state. Public name search still exposes roster names to anyone who can access the page.


## Combined latest package (student portal + admin controls + PWA)

This package combines the separate student-facing kiosk (`student.html`), admin dashboard, attendance entry deletion, per-action session enable controls, roster deactivation migration, and PWA manifest/icons. Deploy the whole folder over HTTPS. Run `student-portal-migration.sql` and `student-deletion-admin.sql` in Supabase only if those migrations have not already been applied. Do not expose a Supabase service-role key in client-side files.

PWA installation is supported only in compatible browsers and typically requires HTTPS. Offline entries are stored per device and synchronize only after that device reconnects; test on real devices before official use.

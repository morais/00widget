import type { StartTokenRow } from "./storage";

/// How long a push-to-start token may go unrefreshed before it is treated as
/// belonging to a device that no longer runs the app.
///
/// The app re-registers its start token on every launch, background launches
/// included, and the upsert always rewrites `updated_at` — so a row's age is
/// how long the app has not run on that device. A device that receives Live
/// Activities is woken to register them and stays fresh on its own. What ages
/// out is a reinstall's abandoned `deviceId` or a phone put in a drawer: APNs
/// keeps answering 200 for those, so the dead-token pruning in the start path
/// never sees them, and every start fans out to a device that will never
/// register the activity it was sent.
///
/// Being wrong is cheap in one direction only, which is why this is long: a
/// dormant device dropped here misses activities until its app next launches
/// and re-registers, and nothing is lost for good.
export const START_TOKEN_MAX_AGE_DAYS = 30;

/// A token refreshed within this window counts as recently active in the
/// counts reported back to producers. Reporting only, never enforcement.
export const START_TOKEN_RECENT_DAYS = 7;

const DAY_MS = 24 * 60 * 60 * 1000;

export interface PartitionedStartTokens {
  live: StartTokenRow[];
  stale: StartTokenRow[];
  recentlyActive: number;
  /// The `updated_at` bound the stale rows fall below, for the delete.
  staleCutoff: string;
}

export function partitionStartTokens(
  rows: StartTokenRow[],
  now = Date.now(),
): PartitionedStartTokens {
  const staleCutoff = new Date(now - START_TOKEN_MAX_AGE_DAYS * DAY_MS).toISOString();
  const recentMs = now - START_TOKEN_RECENT_DAYS * DAY_MS;
  const live: StartTokenRow[] = [];
  const stale: StartTokenRow[] = [];
  let recentlyActive = 0;
  for (const row of rows) {
    // Compared as strings, exactly as the delete compares them in SQL, so the
    // rows reported stale are the rows the delete removes. Every `updated_at`
    // is written by `nowIso`, so the ISO strings order chronologically.
    if (row.updatedAt < staleCutoff) {
      stale.push(row);
      continue;
    }
    live.push(row);
    if (Date.parse(row.updatedAt) >= recentMs) recentlyActive++;
  }
  return { live, stale, recentlyActive, staleCutoff };
}

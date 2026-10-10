# Notification reliability review

The upstream reports reviewed were Android #149, #137, #136, #89 and macOS #294, #271.

## Implemented

- Android preserves the existing persisted notification ID through updates and process restart. New notifications use collision-resistant per-lifetime IDs instead of package/title/time combinations.
- Commands resolve the exact ID against **currently active system notifications**. This refreshes PendingIntents after updates and avoids acting on stale cached objects. Ambiguous legacy IDs are rejected, with no package/title guessing.
- Duplicate action titles are not exposed or executed. Empty/blank replies cannot accidentally invoke a reply PendingIntent as a button. Text is attached only to free-form reply inputs. A "Mark as read" button appears only when the source Android app actually supplies it.
- Removal bookkeeping runs immediately, including while paused/offline. Duplicate removals do not transmit raw Android keys. Queued posts are checked against the system's current notification before transmission.
- Android-origin removals no longer echo another dismissal back from the Mac. Mac native dismissal and Clear All honor the existing phone-dismiss setting.
- Notification Center reconciliation only treats a previously observed delivered notification as removed; a muted, denied, or not-yet-delivered notification does not trigger dismissal on Android.
- macOS notification categories are registered through one serialized registry. Quick Share and call categories no longer erase reply/action categories. Unchanged definitions skip category writes. Dynamic categories distinguish buttons from text replies, have bounded identifier lengths, and prune inactive entries above 128 while retaining visible/pending actions. Incoming and outgoing call categories are distinct.
- Android app-filter writes from remote single/bulk toggles and automatic app discovery use atomic preference mutations, coordinated with the app-selection changes.

## Verification and limits

Ten Android production-policy unit tests cover exact recovery, stale/ambiguous IDs, supported actions, missing/empty/blank text, and reply bounds. Twelve native Swift production-policy checks cover category identity and safe Notification Center dismissal detection. The root workflow runs their integrated builds; this review does not claim a physical Samsung test.

Android still controls which notifications may be dismissed and which actions can be invoked. Ongoing/non-clearable notifications are rejected; a successful PendingIntent invocation does not guarantee the third-party app completes its action. When notification access is unavailable, commands fail safely. Android can reuse a system key after a notification is removed; per-lifetime IDs rotate on observed removals, but if the operating system omits both removal and replacement history during listener downtime there is no universal API that reconstructs that history. The implementation never guesses a different key.

Cross-app content matching between native WhatsApp on macOS and the Android app is not used: macOS does not expose other applications' notification content as a general-purpose API. Per-app selection is the supported way to avoid both native and mirrored alerts.

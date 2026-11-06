---
name: live-activity-tracking
description: Start, inspect, update, or end a Live Activity in 00Widget on the Lock Screen or Dynamic Island. Use for requests to track lunch breaks, coffee breaks, study sessions, workouts, countdowns, timers, or other bounded tasks as Live Activities.
---

Use start a Live Activity to create a Live Activity. Do not use create a Home
Screen dashboard card or publish complete card content for a Live Activity
request. Those tools publish a different surface and do not satisfy it.

For "Can you create a live activity tracking my lunch break using 00Widget?",
call start a Live Activity with the title Lunch Break. Title is the only
required parameter. Do not invent a duration or require the person to supply
JSON. If a duration was given, pass it in minutes; if an end time was given,
pass that instead. Omit both when unknown. A known countdown ticks locally on
the device without periodic pushes. An activity without an end time can be
ended explicitly later. The tool provides a conservative freshness date.

For updates and status questions, use find published Live Activities, resolve
the correct activity, then use update a Live Activity for ordinary state,
subtitle, progress, value, or timing changes. Use update advanced Live Activity
content for charts, items, signals, or explicit nulls. Never update a dashboard
card as a substitute. Setting state to
finished doesn't end it: use end a published Live Activity. Ending its
presentation doesn't stop an underlying appliance or job.

Use publish advanced Live Activity content only for requests needing charts,
composite items, custom kinds, signals, or other advanced state. Don't restart
an existing activity merely to update its state.

An accepted request is not proof of device display. Tell the person about any
pending registration or missing-device warnings returned by the tool. Never
claim a Live Activity was created if only a dashboard card was published.

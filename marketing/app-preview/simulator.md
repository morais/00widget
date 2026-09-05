# One-time App Preview Simulator setup

The v1 capture treats SpringBoard as a prepared stage. It deliberately does not
install, edit, move, or remove Home Screen widgets on every run.

## Create the device

The marketing Simulator is provisioned deliberately, never as a capture side
effect — creating it wipes the hand-placed hero page a capture films:

```sh
./marketing/app-preview/run.sh ios-main --create-device
```

This reads `device.name`, `device.deviceType`, and `device.runtime` from
`marketing/app-preview/ios-main.yaml`, creates the Simulator, boots it, opens
Simulator.app on it, and sets the configured appearance. If a device with the
same name already exists the command refuses; pass `--replace` to shut it
down, delete it, and create it again. An existing hand-made device on another
runtime can stay, but the capture resolves `device.runtime` and will not see
it — either recreate through this command or narrow the pin.

Then build, install, and launch once so the private widget configurations
appear in the gallery:

```sh
./marketing/app-preview/run.sh ios-main --prepare-only
```

This command does not record, run the timeline, uninstall the app, or alter the
Home Screen. It leaves Simulator.app open with 00Widget running in offline
marketing mode. Alternatively, build the `ZeroZeroWidgetScreenshots` scheme in
Xcode with `ZW_SHARING_ENABLED ZW_SCREENSHOTS` active.

## Prepare the visual stage

Configure the device once:

- choose the final wallpaper and explicit light appearance;
- remove distracting apps from the hero capture page;
- disable notifications or enable a Focus that suppresses banners;
- leave the keyboard dismissed and turn off pointer/touch visualizations;
- prepare the desired Lock Screen separately if a future timeline uses it;
- do not erase this Simulator after the layout is ready.

Place one hero Home Screen page, starting at the first ordinary page
after iOS's far-left Today/widgets view:

1. `Preview Launch`, `Preview Production`, and `Preview Open PRs` as three
   small widgets in the top row, with `Preview Trials Wide` directly below
   them — the same three-small-plus-wide composition as the classic
   marketing screenshot page.

The names above are private static widget configurations compiled only into the
screenshot scheme. They use the production card renderer but do not depend on
AppIntent entity restoration, which is unreliable in the Simulator. Keep this
page at `stage.initialPage`; the timeline holds it for the opening beats,
updates the `App launch` Live Activity over it, and returns to it for the
brand end frame.

Launch 00Widget once with the marketing build before judging the widget data.
The capture test does this on every run and explicitly asks WidgetCenter to
reload. It uses the fixture reference date from the config, performs no network
request, never asks for notification permission, lands on Widgets without
authentication, and suppresses sample badges.

## What each run changes

The script boots the designated device, opens Simulator.app on that UDID,
installs the current build without uninstalling, pins supported status-bar
fields, and sets appearance. It does not erase the Simulator, delete app/widget
state, edit SpringBoard, change the wallpaper, or touch global Xcode settings.
The temporary status-bar override is cleared at the end.

Widget placement can still be lost if the widget kind or app bundle identifier
changes. Restore the hero page manually if that happens. Verify the stage
visually before a release capture; SpringBoard remains the only intentionally
manual part of v1.

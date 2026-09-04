#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any

from config import ConfigError, artifact_directory, load_config, repository_root
from render import render
from simulator import (
    SimulatorError,
    app_container,
    boot,
    clear_status_bar,
    configure_visual_state,
    require_tool,
    resolve_device,
)
from validate import ValidationError, validate


class PreviewError(RuntimeError):
    pass


class Logger:
    def __init__(self, verbose: bool = False) -> None:
        self.verbose = verbose
        self.capture_started: float | None = None

    def info(self, message: str) -> None:
        if self.capture_started is None:
            print(f"→ {message}", flush=True)
        else:
            elapsed = time.monotonic() - self.capture_started
            print(f"[{elapsed:06.3f}] {message}", flush=True)

    def command(self, command: list[str]) -> None:
        if self.verbose:
            print("+ " + " ".join(command), flush=True)


def run(command: list[str], logger: Logger, *, cwd: Path | None = None, output: Any = None) -> None:
    logger.command(command)
    subprocess.run(
        command,
        check=True,
        cwd=cwd,
        stdout=output,
        stderr=subprocess.STDOUT if output else None,
    )


def tail(path: Path, lines: int = 50) -> str:
    if not path.is_file():
        return "(log was not created)"
    return "\n".join(path.read_text(errors="replace").splitlines()[-lines:])


def find_latest(root: Path, pattern: str, label: str) -> Path:
    matches = sorted(root.glob(pattern))
    if not matches:
        raise PreviewError(f"expected a {label} under {root}, found none")
    return max(matches, key=lambda path: path.stat().st_mtime_ns)


def build_products(
    config: dict[str, Any],
    device_name: str,
    temp_dir: Path,
    supplied_app: Path | None,
    logger: Logger,
) -> tuple[Path, Path, str, Path]:
    root = repository_root()
    ios_root = root / "ios"
    project = ios_root / "ZeroZeroWidget.xcodeproj"
    if not (ios_root / "project.yml").is_file():
        raise PreviewError(
            "ios/project.yml is missing; copy ios/project.yml.sample and configure it before capture"
        )
    require_tool("xcodegen")
    require_tool("xcodebuild")
    logger.info("Generating the Xcode project")
    run(["xcodegen", "generate"], logger, cwd=ios_root)
    if not project.is_dir():
        raise PreviewError("xcodegen did not create ios/ZeroZeroWidget.xcodeproj")

    derived = Path(
        os.environ.get(
            "ZW_APP_PREVIEW_DERIVED_DATA",
            str(ios_root / "build" / "AppPreviewDerivedData"),
        )
    )
    build_log = temp_dir / "build.log"
    conditions = str(config.get("build", {}).get("swiftConditions", "ZW_SHARING_ENABLED ZW_SCREENSHOTS"))
    command = [
        "xcodebuild",
        "build-for-testing",
        "-project",
        str(project),
        "-scheme",
        str(config.get("build", {}).get("scheme", "ZeroZeroWidgetScreenshots")),
        "-destination",
        f"platform=iOS Simulator,name={device_name}",
        "-derivedDataPath",
        str(derived),
        'CODE_SIGN_IDENTITY=-',
        "CODE_SIGNING_REQUIRED=NO",
        f"SWIFT_ACTIVE_COMPILATION_CONDITIONS={conditions}",
    ]
    logger.info("Building the app and preview UI test")
    with build_log.open("wb") as handle:
        try:
            run(command, logger, cwd=ios_root, output=handle)
        except subprocess.CalledProcessError as exc:
            raise PreviewError(f"preview build failed:\n{tail(build_log)}") from exc

    products = derived / "Build" / "Products"
    built_app = products / "Debug-iphonesimulator" / "ZeroZeroWidgetApp.app"
    if not built_app.is_dir():
        raise PreviewError(f"built app was not found: {built_app}")
    selected_app = supplied_app or built_app
    if not selected_app.is_dir() or selected_app.suffix != ".app":
        raise PreviewError(f"--app must point to an iOS Simulator .app bundle: {selected_app}")

    if not supplied_app:
        resign_for_simulator(built_app, temp_dir, logger)
    xctestrun = find_latest(products, "ZeroZeroWidgetScreenshots_*.xctestrun", "xctestrun file")
    runner = products / "Debug-iphonesimulator" / "ZeroZeroWidgetUITests-Runner.app"
    if not runner.is_dir():
        raise PreviewError(f"UI test runner was not found: {runner}")
    with (runner / "Info.plist").open("rb") as handle:
        runner_bundle_id = plistlib.load(handle)["CFBundleIdentifier"]
    return selected_app, xctestrun, runner_bundle_id, products


def resign_for_simulator(app: Path, temp_dir: Path, logger: Logger) -> None:
    with (app / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    app_group = info.get("ZWAppGroupIdentifier")
    if not app_group:
        raise PreviewError("built app has no ZWAppGroupIdentifier in Info.plist")
    entitlements = temp_dir / "sim.entitlements"
    with entitlements.open("wb") as handle:
        plistlib.dump({"com.apple.security.application-groups": [app_group]}, handle)
    extension = app / "PlugIns" / "ZeroZeroWidgetWidgets.appex"
    if not extension.is_dir():
        raise PreviewError(f"widget extension was not found: {extension}")
    logger.info("Re-signing the app and widget with Simulator App Group entitlements")
    subprocess.run(
        ["codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(extension)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        ["codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(app)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def prepare_xctestrun(
    source: Path,
    destination: Path,
    run_id: str,
    selected_app: Path,
    built_products: Path,
) -> None:
    with source.open("rb") as handle:
        payload = plistlib.load(handle)

    def resolve_testroot(value: Any) -> Any:
        if isinstance(value, str):
            return value.replace("__TESTROOT__", str(built_products))
        if isinstance(value, list):
            return [resolve_testroot(item) for item in value]
        if isinstance(value, dict):
            return {key: resolve_testroot(item) for key, item in value.items()}
        return value

    # xcodebuild defines __TESTROOT__ as the directory containing the copied
    # xctestrun. Resolve it before moving the plan into our temporary run
    # directory, or the runner/test bundles are looked up beside that copy.
    payload = resolve_testroot(payload)
    keys = [key for key in payload if not key.startswith("__")]
    if len(keys) != 1:
        raise PreviewError(f"could not identify the UI test entry in {source}")
    test = payload[keys[0]]
    environment = test.setdefault("EnvironmentVariables", {})
    environment["ZW_APP_PREVIEW_RUN_ID"] = run_id
    test["UITargetAppPath"] = str(selected_app)
    dependencies = test.get("DependentProductPaths", [])
    built_app_path = str(built_products / "Debug-iphonesimulator" / "ZeroZeroWidgetApp.app")
    test["DependentProductPaths"] = [
        str(selected_app) if value == built_app_path else value for value in dependencies
    ]
    # Absolute paths in UITargetAppPath are accepted, but keep the macro root
    # meaningful for the runner/test bundle and its framework search paths.
    test["TestingEnvironmentVariables"]["ZW_APP_PREVIEW_PRODUCTS"] = str(built_products)
    with destination.open("wb") as handle:
        plistlib.dump(payload, handle)


def atomic_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def wait_for(
    predicate: Any,
    timeout: float,
    description: str,
    *,
    process: subprocess.Popen[Any] | None = None,
    process_log: Path | None = None,
) -> Any:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        if process is not None and process.poll() is not None:
            details = f"\n{tail(process_log)}" if process_log else ""
            raise PreviewError(f"UI test exited before {description}{details}")
        time.sleep(0.1)
    raise PreviewError(f"timed out waiting for {description}")


def stop_process(process: subprocess.Popen[Any] | None, sig: signal.Signals, timeout: float = 20) -> None:
    if process is None or process.poll() is not None:
        return
    process.send_signal(sig)
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def capture(
    config: dict[str, Any],
    config_path: Path,
    device_name: str,
    supplied_app: Path | None,
    raw_path: Path,
    temp_dir: Path,
    logger: Logger,
) -> dict[str, Any]:
    udid, runtime = resolve_device(device_name, config["device"].get("runtime"))
    logger.info(f"Using {device_name} ({runtime}, {udid})")
    boot(udid, logger.info)
    try:
        configure_visual_state(udid, {**config["device"], "statusBar": config["statusBar"]})
        return capture_with_configured_simulator(
            config,
            config_path,
            device_name,
            supplied_app,
            raw_path,
            temp_dir,
            logger,
            udid,
            runtime,
        )
    finally:
        clear_status_bar(udid)


def prepare_simulator(
    config: dict[str, Any],
    device_name: str,
    supplied_app: Path | None,
    temp_dir: Path,
    logger: Logger,
) -> dict[str, str]:
    udid, runtime = resolve_device(device_name, config["device"].get("runtime"))
    logger.info(f"Using {device_name} ({runtime}, {udid})")
    boot(udid, logger.info)
    try:
        configure_visual_state(udid, {**config["device"], "statusBar": config["statusBar"]})
        selected_app, _, _, _ = build_products(config, device_name, temp_dir, supplied_app, logger)
        with (selected_app / "Info.plist").open("rb") as handle:
            bundle_id = plistlib.load(handle)["CFBundleIdentifier"]
        logger.info("Installing the private preview build without clearing its data")
        run(["xcrun", "simctl", "install", udid, str(selected_app)], logger)
        fixtures = config.get("fixtures", {})
        fixtures_payload = base64.b64encode(
            json.dumps(fixtures, separators=(",", ":")).encode("utf-8")
        ).decode("ascii")
        launch = [
            "xcrun",
            "simctl",
            "launch",
            udid,
            bundle_id,
            "--marketing-demo",
            "--marketing-fixtures",
            fixtures_payload,
        ]
        if fixtures.get("referenceDate"):
            launch.extend(["--marketing-reference-date", str(fixtures["referenceDate"])])
        preview_phase = config.get("preview", {}).get("initialPhase")
        if preview_phase:
            launch.extend(["--preview-launch-phase", str(preview_phase)])
        logger.info("Launching 00Widget in offline marketing mode")
        run(launch, logger)
        return {"udid": udid, "runtime": runtime, "bundleId": bundle_id}
    finally:
        clear_status_bar(udid)


def capture_with_configured_simulator(
    config: dict[str, Any],
    config_path: Path,
    device_name: str,
    supplied_app: Path | None,
    raw_path: Path,
    temp_dir: Path,
    logger: Logger,
    udid: str,
    runtime: str,
) -> dict[str, Any]:
    selected_app, xctestrun, runner_bundle_id, products = build_products(
        config, device_name, temp_dir, supplied_app, logger
    )
    run_id = uuid.uuid4().hex
    private_xctestrun = temp_dir / xctestrun.name
    prepare_xctestrun(xctestrun, private_xctestrun, run_id, selected_app, products)

    test_log = temp_dir / "xcodebuild-test.log"
    test_command = [
        "xcodebuild",
        "test-without-building",
        "-xctestrun",
        str(private_xctestrun),
        "-destination",
        f"platform=iOS Simulator,id={udid}",
        "-only-testing:ZeroZeroWidgetUITests/MarketingPreviewTests/testRunConfiguredPreview",
    ]
    logger.info("Launching the preview driver")
    logger.command(test_command)
    test_handle = test_log.open("wb")
    test_process = subprocess.Popen(
        test_command,
        cwd=repository_root() / "ios",
        stdout=test_handle,
        stderr=subprocess.STDOUT,
    )
    recorder: subprocess.Popen[Any] | None = None
    recorder_handle: Any = None
    handshake_dir: Path | None = None
    try:
        def configured_ready_directory() -> Path | None:
            # Xcode can replace the runner's data-container UUID while
            # installing a new build. Resolve it on every poll and copy the
            # run config forward; retaining the pre-install path deadlocks
            # while the test quite correctly signals in its new container.
            container = app_container(udid, runner_bundle_id)
            if container is None:
                return None
            current = container / "Documents" / "AppPreview" / run_id
            if not (current / "config.json").is_file():
                atomic_json(current / "config.json", config)
            return current if (current / "ready").is_file() else None

        handshake_dir = wait_for(
            configured_ready_directory,
            180,
            "the prepared Home Screen stage",
            process=test_process,
            process_log=test_log,
        )
        logger.info("Preview stage is ready")

        # Ask CoreSimulator for one full, settled framebuffer before starting
        # recordVideo. Without this priming read, the movie's first keyframe can
        # contain a stale partial SpringBoard swipe even though the page has
        # already been stationary for a second.
        run(
            [
                "xcrun",
                "simctl",
                "io",
                udid,
                "screenshot",
                str(temp_dir / "stage-prime.png"),
            ],
            logger,
        )

        raw_path.parent.mkdir(parents=True, exist_ok=True)
        if raw_path.exists():
            raw_path.unlink()
        recorder_log = temp_dir / "record-video.log"
        recorder_handle = recorder_log.open("wb")
        record_command = [
            "xcrun",
            "simctl",
            "io",
            udid,
            "recordVideo",
            "--codec=h264",
            "--mask=ignored",
            str(raw_path),
        ]
        logger.command(record_command)
        recorder = subprocess.Popen(record_command, stdout=recorder_handle, stderr=subprocess.STDOUT)
        wait_for(
            lambda: recorder_log.is_file() and "Recording started" in recorder_log.read_text(errors="replace"),
            20,
            "Simulator framebuffer recording to initialize",
            process=recorder,
            process_log=recorder_log,
        )
        logger.capture_started = time.monotonic()
        logger.info("Recording started")
        (handshake_dir / "start").write_text("start\n", encoding="utf-8")
        wait_for(
            lambda: (handshake_dir / "finished").is_file(),
            float(config["output"]["duration"]) + 30,
            "the preview timeline to finish",
            process=test_process,
            process_log=test_log,
        )
        logger.info("Timeline finished")
        stop_process(recorder, signal.SIGINT)
        recorder = None
        if not raw_path.is_file() or raw_path.stat().st_size == 0:
            raise PreviewError(f"recording produced no movie: {raw_path}")

        try:
            test_process.wait(timeout=90)
        except subprocess.TimeoutExpired as exc:
            raise PreviewError("UI test did not exit after its timeline finished") from exc
        if test_process.returncode:
            raise PreviewError(f"preview UI test failed:\n{tail(test_log)}")
        events = []
        event_path = handshake_dir / "events.jsonl"
        if event_path.is_file():
            for line in event_path.read_text(encoding="utf-8").splitlines():
                event = json.loads(line)
                events.append(event)
                print(f"[{event['time']:06.3f}] {event['label']}")
        return {
            "udid": udid,
            "runtime": runtime,
            "device": device_name,
            "runId": run_id,
            "rawPath": str(raw_path),
            "rawSizeBytes": raw_path.stat().st_size,
            "events": events,
            "config": str(config_path),
        }
    finally:
        stop_process(recorder, signal.SIGINT)
        stop_process(test_process, signal.SIGTERM, timeout=10)
        test_handle.close()
        if recorder_handle:
            recorder_handle.close()


def write_report(path: Path, report: dict[str, Any]) -> None:
    atomic_json(path, report)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Capture, render, and validate a deterministic 00Widget App Store Preview"
    )
    parser.add_argument("profile", nargs="?", default="ios-main")
    parser.add_argument("--app", type=Path, help="use a supplied iOS Simulator .app bundle")
    parser.add_argument("--device", help="override device.name from the config")
    parser.add_argument("--config", help="use an explicit JSON-compatible YAML config")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--raw-only", action="store_true", help="capture raw.mov without rendering")
    mode.add_argument("--render-only", action="store_true", help="render the existing raw.mov")
    mode.add_argument(
        "--prepare-only",
        action="store_true",
        help="build, install, and open the Simulator for one-time manual stage setup",
    )
    parser.add_argument("--keep-temp", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    logger = Logger(args.verbose)
    temp_dir = Path(tempfile.mkdtemp(prefix="00widget-app-preview-"))

    def terminate_cleanly(signum: int, frame: Any) -> None:
        raise KeyboardInterrupt(f"received signal {signum}")

    signal.signal(signal.SIGTERM, terminate_cleanly)
    try:
        config, config_path = load_config(args.profile, args.config)
        output_dir = artifact_directory(config)
        output_dir.mkdir(parents=True, exist_ok=True)
        raw_path = output_dir / "raw.mov"
        preview_path = output_dir / "preview.mp4"
        report_path = output_dir / "preview.json"
        config_hash = hashlib.sha256(config_path.read_bytes()).hexdigest()
        report: dict[str, Any] = {
            "profile": args.profile,
            "configPath": str(config_path),
            "configSHA256": config_hash,
            "output": str(preview_path),
        }

        if args.prepare_only:
            prepared = prepare_simulator(
                config,
                args.device or config["device"]["name"],
                args.app.resolve() if args.app else None,
                temp_dir,
                logger,
            )
            print(f"✓ {args.device or config['device']['name']} is open and ready to configure")
            print(f"  UDID: {prepared['udid']}")
            return 0

        if not args.render_only:
            require_tool("xcrun")
            capture_report = capture(
                config,
                config_path,
                args.device or config["device"]["name"],
                args.app.resolve() if args.app else None,
                raw_path,
                temp_dir,
                logger,
            )
            report["capture"] = capture_report
            if args.raw_only:
                report["validation"] = None
                write_report(report_path, report)
                print(f"✓ raw capture: {raw_path}")
                print(f"✓ report: {report_path}")
                return 0
        elif not raw_path.is_file():
            raise PreviewError(f"--render-only requires an existing raw capture: {raw_path}")

        require_tool("ffmpeg")
        require_tool("ffprobe")
        if args.render_only:
            existing_report = {}
            if report_path.is_file():
                existing_report = json.loads(report_path.read_text(encoding="utf-8"))
            report.update({key: value for key, value in existing_report.items() if key == "capture"})
        report["overlays"] = render(
            raw_path,
            preview_path,
            config,
            temp_dir / "overlays",
            log=logger.info,
        )
        logger.info("Validating App Store Preview output")
        report["validation"] = validate(preview_path, config)
        write_report(report_path, report)
        print(f"✓ raw capture (untrimmed, no text): {raw_path}")
        print(f"✓ preview: {preview_path}")
        print(f"✓ report: {report_path}")
        return 0
    except (ConfigError, PreviewError, SimulatorError, ValidationError, subprocess.CalledProcessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("error: preview capture interrupted; recorder and UI test were cleaned up", file=sys.stderr)
        return 130
    finally:
        if args.keep_temp:
            print(f"→ temporary files kept at {temp_dir}")
        else:
            shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())

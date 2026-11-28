"""Shared interlock and recovery for the opt-in live fixture checks."""
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

APP = Path.home() / "Applications/AeroGrid.app"
CONTROLLER = APP / "Contents/MacOS/AeroGrid"
CLI = APP.with_name("AeroGrid Backend.app") / "Contents/Resources/aerospace"
ROOT = Path.home() / "Library/Caches/AeroGrid/LiveFixtures"
FIXTURE = Path(__file__).resolve().parents[1] / "dist/GridFixture"
SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)


def command(*args, executable=CLI):
    result = subprocess.run([str(executable), *map(str, args)], capture_output=True, text=True, timeout=12)
    if result.returncode:
        raise RuntimeError(f"{Path(executable).name} rejected {args[-1] if args[0] == 'grid-layout' else args[0]}")
    return result.stdout.strip()


def status():
    return json.loads(command("grid-layout", "--data", "diagnostics", "status"))


def write_json(path, data):
    stage = path.with_suffix(".tmp")
    stage.write_text(json.dumps(data))
    stage.replace(path)


def wait_for(check, description, seconds=16):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.25)
    raise RuntimeError(f"Timed out waiting for {description}")


def try_lock(fd):
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False


def activate(workspace, monitor):
    command("grid-layout", "--workspace", workspace, "--data", json.dumps({"monitor": int(monitor)}), "activate-target")


def native_by_monitor(observation):
    native = observation.get("placementDiagnostics", {}).get("nativeDisplays", [])
    return {str(d["monitor"]): d for d in native if d.get("monitor") is not None}


def normal(display):
    return any(space["type"] == 0 and space["id"] == display["current"] for space in display["spaces"])


def capture(observation):
    displays = {str(d["monitor"]): d["id"] for d in observation["displays"]}
    native = native_by_monitor(observation)
    if (observation.get("extensionVersion", 0) < 3 or observation["placementDiagnostics"]["locked"]
            or set(native) != set(displays) or set(observation["visible"]) != set(displays)):
        raise RuntimeError("An unlocked session, matching backend v3 and native Spaces on each display are required")
    focused_id = observation.get("focusedWindow")
    focused = next((w for w in observation["windowHomes"] if w["id"] == focused_id), None)
    if focused_id is not None and focused is None:
        raise RuntimeError("The current focused window cannot be recovered")
    return {"displays": displays, "visible": observation["visible"],
            "native": {key: value["current"] for key, value in native.items()},
            "focusedMonitor": observation["focusedMonitor"], "focused": focused,
            "focusWasFrontmost": observation["placementDiagnostics"].get("frontmostMatchesFocusedWindowOwner", False)}


def restore(original):
    """Restore by physical display identity; refuse to replay stale numeric monitor IDs."""
    current = status()
    monitors = {d["id"]: str(d["monitor"]) for d in current["displays"]}
    if set(monitors) != set(original["displays"].values()):
        raise RuntimeError("Reconnect the original displays before recovering the fixture session")
    remap = {key: monitors[identity] for key, identity in original["displays"].items()}
    visible = {remap[key]: workspace for key, workspace in original["visible"].items()}
    native = {remap[key]: space for key, space in original["native"].items()}
    focused_monitor = remap[str(original["focusedMonitor"])]
    focused = original["focused"]
    for monitor, workspace in visible.items():
        if status()["visible"].get(monitor) != workspace:
            activate(workspace, monitor)
    for monitor in sorted(native, key=lambda m: m == focused_monitor):
        observed = native_by_monitor(status()).get(monitor, {})
        if observed.get("current") != native[monitor]:
            command("grid-layout", "--data", native[monitor], "native-focus")

    def matching_focus(observation):
        return focused and any(all(home[key] == focused[key] for key in ("id", "pid", "boot"))
                               for home in observation["windowHomes"])

    def focus_matches(observation):
        return (observation.get("focusedWindow") == focused["id"]
                and (not original.get("focusWasFrontmost")
                     or observation["placementDiagnostics"].get("frontmostMatchesFocusedWindowOwner")))

    current = status()
    if matching_focus(current):
        if not focus_matches(current):
            command("focus", "--window-id", focused["id"])
    elif str(current["focusedMonitor"]) != focused_monitor:
        command("focus-monitor", focused_monitor)

    def restored():
        observed = status()
        return (observed["visible"] == visible and str(observed["focusedMonitor"]) == focused_monitor
                and all(native_by_monitor(observed).get(key, {}).get("current") == space for key, space in native.items())
                and (not matching_focus(observed) or focus_matches(observed)))

    wait_for(restored, "original workspaces, native Spaces and surviving focus", seconds=8)


class Session:
    def __init__(self, directory):
        self.directory = directory
        self.workspace = "grid-fixture-" + directory.name
        self.fixture = None
        self.verifier = None

    def register_fixture(self, display, backend_session, allow_backend_restart):
        self.fixture = subprocess.Popen([str(self.directory / "GridFixture")],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.pid = self.fixture.pid
        write_json(self.directory / "fixture.json", {"pid": self.pid, "workspace": self.workspace, "display": display,
                                                     "originalBackend": backend_session, "allowBackendRestart": allow_backend_restart})
        self.monitor = display["monitor"]

        def three():
            desktop = status()
            homes = desktop["windowHomes"]
            if any(w["pid"] == self.pid and w["workspace"] != self.workspace for w in homes):
                raise RuntimeError("A backend rule routed a fixture window outside the isolated workspace")
            if any(w["pid"] != self.pid and w["workspace"] == self.workspace for w in homes):
                raise RuntimeError("Another app entered the isolated workspace")
            windows = [w for w in desktop["windows"] if w["pid"] == self.pid]
            return windows if len(windows) == 3 else None

        self.windows = wait_for(three, "three owned fixture windows")

    def start_verifier(self, mode, *args):
        with (self.directory / "verifier.log").open("w") as log:
            self.verifier = subprocess.Popen([str(CONTROLLER), mode, self.directory.name, *args], stdout=log, stderr=log)
        return self.verifier

    def jump(self, cell):
        self.check_observer()
        write_json(self.directory / "jump.json", cell)

    def check_observer(self):
        if self.verifier.poll() is not None:
            raise RuntimeError("The fixture observer exited. See verifier.log in the private run directory")

    def close_children(self):
        if self.verifier and self.verifier.poll() is None:
            (self.directory / "stop-observer").touch()
            try:
                self.verifier.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.verifier.terminate()
                try:
                    self.verifier.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.verifier.kill()
                    self.verifier.wait(timeout=5)
        if self.fixture and self.fixture.poll() is None:
            self.fixture.terminate()
            try:
                self.fixture.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.fixture.kill()
                self.fixture.wait(timeout=5)

    def reap_orphans(self):
        # A runner can be killed before recording a child PID. Match only the unique
        # run's own executable or verification invocation, never by app name or stale PID.
        def owned_processes():
            result = subprocess.check_output(["/bin/ps", "-axww", "-o", "pid=,command="], text=True)
            for line in result.splitlines():
                fields = line.strip().split(maxsplit=1)
                if len(fields) != 2:
                    continue
                pid, invocation = fields
                if invocation == str(self.directory / "GridFixture") or invocation in {
                    f"{CONTROLLER} --fixture-observe {self.directory.name}",
                    f"{CONTROLLER} --verify-dynamic-fixtures {self.directory.name}",
                    f"{CONTROLLER} --verify-dynamic-fixtures {self.directory.name} --normal-only",
                }:
                    yield int(pid)

        def send(sig):
            for pid in owned_processes():
                try:
                    os.kill(pid, sig)
                except ProcessLookupError:
                    pass

        (self.directory / "stop-observer").touch()
        send(signal.SIGTERM)
        try:
            wait_for(lambda: not list(owned_processes()), "fixture subprocesses to exit", seconds=5)
        except RuntimeError:
            send(signal.SIGKILL)
            wait_for(lambda: not list(owned_processes()), "fixture subprocesses to exit", seconds=5)

    def cancel_handoff(self, interlock):
        (self.directory / "handoff-request").unlink(missing_ok=True)
        if (self.directory / "handoff-started").exists():
            wait_for(lambda: try_lock(interlock), "the ordinary controller to finish quitting")

    def finish(self, interlock):
        journal = self.directory / "original.json"
        if journal.exists():
            blind = self.directory / "blind-window.json"
            if blind.exists():
                command("grid-layout", "--data", json.dumps({"windowID": json.loads(blind.read_text()), "seconds": 0}), "debug-blind")
                blind.unlink()
            request = self.directory / "fixture.json"
            if request.exists():
                pid = json.loads(request.read_text())["pid"]
                wait_for(lambda: all(w["pid"] != pid for w in status()["windowHomes"]),
                         "fixture windows to disappear from the backend")
            restore(json.loads(journal.read_text()))
            manifest = self.directory / "fixture-workspaces.json"
            derived = set(json.loads(manifest.read_text())) if manifest.exists() else set()
            if any(home["workspace"].startswith(self.workspace) or home["workspace"] in derived
                   for home in status()["windowHomes"]):
                raise RuntimeError("A window remains in a fixture workspace. Close it before running recovery")
        (ROOT / "active").unlink()
        fcntl.flock(interlock, fcntl.LOCK_UN)
        subprocess.run(["/usr/bin/open", "-g", str(APP)], check=True, timeout=8)


@contextmanager
def locked_runner():
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (ROOT / "runner.lock").open("a") as lock:
        if not try_lock(lock.fileno()):
            raise RuntimeError("Another fixture runner is active")
        fd = os.open(ROOT, os.O_RDONLY | os.O_DIRECTORY)
        try:
            yield fd
        finally:
            os.close(fd)


@contextmanager
def handle_interrupts():
    def interrupt(signum, _):
        raise KeyboardInterrupt(f"Interrupted by {signal.Signals(signum).name}")

    previous = {sig: signal.signal(sig, interrupt) for sig in SIGNALS}
    try:
        yield
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


@contextmanager
def fixture_session(choose_display, *, allow_backend_restart=False):
    with locked_runner() as fd, handle_interrupts():
        active = ROOT / "active"
        if active.is_symlink():
            raise RuntimeError("An earlier fixture run needs recovery. Run scripts/run-live-smoke.py --recover")
        session = Session(Path(tempfile.mkdtemp(prefix="run-", dir=ROOT)))
        shutil.copy2(FIXTURE, session.directory / "GridFixture")
        print(f"Private fixture output: {session.directory}", flush=True)
        try:
            active.symlink_to(session.directory.name)
            request = session.directory / "handoff-request"
            request.touch()
            started = session.directory / "handoff-started"

            def handoff_started():
                if started.exists():
                    return True
                # A new controller may have registered before AppModel is ready to quit.
                if not command("--fixture-handoff", executable=CONTROLLER).isdigit():
                    raise RuntimeError("The installed controller does not support fixture isolation")
                return started.exists()

            wait_for(handoff_started, "the ordinary controller to accept fixture handoff")
            ready = session.directory / "handoff-ready"
            wait_for(lambda: ready.exists() and try_lock(fd), "the ordinary controller to quit and release the backend")
            observation = status()
            original = capture(observation)
            display = choose_display(observation)
            if not normal(native_by_monitor(observation)[str(display["monitor"])]):
                raise RuntimeError("Use a normal macOS desktop on the fixture display")
            workspaces = {item["name"] for item in observation["placementDiagnostics"]["workspaces"]}
            if any(name.startswith(session.workspace) for name in workspaces):
                raise RuntimeError("The fixture workspace already exists")
            write_json(session.directory / "original.json", original)
            activate(session.workspace, display["monitor"])
            session.register_fixture(display, observation["backendSession"], allow_backend_restart)
            yield session
        finally:
            # Finish teardown on Ctrl-C, a terminal hangup, and explicit termination.
            # A force kill leaves the interlock and journal for explicit recovery.
            for sig in SIGNALS:
                signal.signal(sig, signal.SIG_IGN)
            if active.is_symlink():
                session.cancel_handoff(fd)
                session.close_children()
                if (session.directory / "original.json").exists():
                    session.reap_orphans()
                session.finish(fd)


def recover():
    with locked_runner() as fd:
        active = ROOT / "active"
        if not active.is_symlink():
            print("No interrupted fixture session")
            return
        name = os.readlink(active)
        if not name.startswith("run-") or Path(name).name != name:
            raise RuntimeError("Invalid fixture recovery path")
        session = Session(ROOT / name)
        session.cancel_handoff(fd)
        if (session.directory / "original.json").exists():
            session.reap_orphans()
        session.finish(fd)
        print("Fixture session recovered")

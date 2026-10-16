"""Preserve TOML syntax and unrelated settings while editing controller-owned values."""
import json
import os
import pathlib
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "vendor/python"))
import tomlkit


def parse(text):
    return tomlkit.parse(text)


def prepare_config(text, required_workspaces, initial_text, previous_manifest):
    document = parse(text)
    initial = parse(initial_text)
    required = set(required_workspaces)
    initial_spaces = set(initial.get("persistent-workspaces", []))
    prior_spaces = document.get("persistent-workspaces", [])
    if not isinstance(prior_spaces, list) or not all(isinstance(value, str) for value in prior_spaces):
        raise ValueError("persistent-workspaces must contain workspace names")
    if "persistent-workspaces" not in document:
        document.add("persistent-workspaces", tomlkit.array())
    for name in sorted(required.difference(prior_spaces)):
        document["persistent-workspaces"].append(name)
    removed = dict(previous_manifest.get("removedAssignments", {}))
    initial_assignments = initial.get("workspace-to-monitor-force-assignment", {})
    if previous_manifest.get("removedMAssignment") and "M" in initial_assignments:
        removed.setdefault("M", initial_assignments.item("M").as_string())
    assignments = document.get("workspace-to-monitor-force-assignment", {})
    for name in required.intersection(assignments):
        removed.setdefault(name, assignments.item(name).as_string())
        del assignments[name]
    owned = (required | set(previous_manifest.get("managedWorkspaces", []))) - initial_spaces
    changes = dict(managedWorkspaces=sorted(owned), removedAssignments=removed)
    updated = tomlkit.dumps(document)
    parse(updated)
    return updated, changes


def remove_owned_settings(text, initial_text, manifest):
    document = parse(text)
    initial = parse(initial_text)
    owned = set(manifest.get("managedWorkspaces", []))
    spaces = document.get("persistent-workspaces")
    if spaces is not None:
        for index in range(len(spaces) - 1, -1, -1):
            if spaces[index] in owned:
                del spaces[index]
        if not spaces and "persistent-workspaces" not in initial:
            del document["persistent-workspaces"]
    removed = dict(manifest.get("removedAssignments", {}))
    initial_assignments = initial.get("workspace-to-monitor-force-assignment", {})
    if manifest.get("removedMAssignment") and "M" in initial_assignments:
        removed.setdefault("M", initial_assignments.item("M").as_string())
    if removed and "workspace-to-monitor-force-assignment" not in document:
        document.add("workspace-to-monitor-force-assignment", tomlkit.table())
    assignments = document.get("workspace-to-monitor-force-assignment", {})
    for name, value in removed.items():
        if name not in assignments:
            item = parse("value = " + value + "\n").item("value")
            assignments.add(name, item)
    result = tomlkit.dumps(document)
    parse(result)
    return result


def atomic_write(path, contents):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    data = contents.encode() if isinstance(contents, str) else contents
    descriptor, temporary = tempfile.mkstemp(prefix=".aerogrid-", dir=str(path.parent))
    try:
        if path.exists():
            os.fchmod(descriptor, path.stat().st_mode & 0o777)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_json(path, value):
    atomic_write(path, json.dumps(value, indent=2) + "\n")

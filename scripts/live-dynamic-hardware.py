#!/usr/bin/env python3
"""Inspect the current disposable dynamic-map fixture; never simulate topology."""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
RECORD = ROOT / 'output/dynamic-hardware.json'
SUPPORT = pathlib.Path.home() / 'Library/Application Support/AeroGrid'
CLI = pathlib.Path.home() / '.local/bin/aerogrid-aerospace'


def command(*args):
    result = subprocess.run([str(CLI), *map(str, args)], capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return result.stdout.strip()


def inspect(stage):
    record = json.loads(RECORD.read_text())
    desktop = json.loads(command('grid-layout', 'status'))
    model = json.loads((SUPPORT / 'state.json').read_text())['dynamicMap']
    ids = {window['id'] for window in record['windows']}
    windows = [window for window in desktop['windows'] if window['id'] in ids and window['pid'] == record['fixturePID']]
    assert len(windows) == 3, 'Fixture membership changed'
    source = record['source']
    family = next((family for family in model['families'] if family['sourceID'] == source['id']), None)
    details = {}
    if stage == 'undocked':
        assert len(desktop['displays']) == 1 and desktop['displays'][0]['builtin'], 'Physically disconnect the ultrawide first'
        assert family and len(family['childIDs']) == 2, 'Expected two blocks from editor + accordion'
        child = next(space for space in model['spaces'] if space.get('sourceID') == source['id'] and not space.get('nativeWindow'))
        stack = json.loads(command('grid-layout', '--workspace', child['workspace'], 'snapshot'))
        assert stack['tree']['layout'] == 'accordion', 'Stack was flattened'
        assert {window['id'] for window in windows if window['workspace'] == child['workspace']} == {window['id'] for window in record['windows'][1:]}, 'Stack membership changed'
        assert len({window['workspace'] for window in windows}) == 2, 'Parallel blocks were not separated'
        details = {'child': child, 'stack': stack}
    elif stage == 'reconnected':
        assert len(desktop['displays']) == 2, 'Reconnect the ultrawide first'
        assert family is None, 'Untouched family was not reunited'
        assert all(window['workspace'] == source['workspace'] for window in windows), 'Windows did not return to their original group'
        actual = json.loads(command('grid-layout', '--workspace', source['workspace'], 'snapshot'))
        assert actual['tree'] == record['wide']['tree'], 'Original nested arrangement/proportions were not restored'
        details = {'restored': actual}
    else:
        raise ValueError('Use undocked or reconnected')
    record['checks'].append({'stage': stage, 'desktop': desktop, 'details': details})
    RECORD.write_text(json.dumps(record, indent=2))
    print('PASS: physical ' + stage + ' checks')


if __name__ == '__main__':
    inspect(sys.argv[1])

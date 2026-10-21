#!/usr/bin/env python3
"""Check an owned spare window across two empty workspaces on adjacent displays."""
import argparse
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--pid', required=True, type=int)
parser.add_argument('--window', required=True, type=int)
parser.add_argument('--left', required=True)
parser.add_argument('--right', required=True)
parser.add_argument('--left-frame', required=True, nargs=4, type=float, metavar=('X', 'Y', 'W', 'H'))
parser.add_argument('--right-frame', required=True, nargs=4, type=float, metavar=('X', 'Y', 'W', 'H'))
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
session = f'kosmos-display-check-{args.window}'
probe = Path(__file__).resolve().parents[1] / '.build/debug/kosmos-probe'


def run(*command):
    return subprocess.run(command, check=True, capture_output=True, text=True, timeout=30).stdout


def state():
    return json.loads(run('kosmos', 'state'))


def cua(tool, **values):
    return json.loads(run('cua-driver', tool, json.dumps(dict(session=session, **values))))


def eui():
    return run(str(probe), 'eui', str(args.pid)).strip().rsplit(': ', 1)[-1]


def move(workspace):
    run('kosmos', 'move-node-to-workspace', '--window-id', str(args.window), '--focus-follows-window', workspace)


start = state()
for name in (args.left, args.right):
    workspace = next(w for w in start['workspaces'] if w['name'] == name)
    if workspace['windows']:
        raise SystemExit(f'Workspace {name} must be empty before this check')
if eui() != 'on':
    raise SystemExit('AXEnhancedUserInterface must already be on to exercise this regression')
if args.output.exists():
    raise SystemExit('Choose a new output path to preserve prior evidence')
listed = [line.split(maxsplit=2) for line in run('kosmos', 'list-windows').splitlines()]
if not any(len(row) >= 2 and row[0] == str(args.window) and row[1] == 'agent' for row in listed):
    raise SystemExit('The spare window must start on the agent workspace')
result = {'version': run('kosmos', 'version').strip(), 'before': start, 'rows': [], 'error': None, 'cleanup_error': None}
cua('start_session')


def check(label, workspace, frame):
    time.sleep(1.2)
    current = state()
    actual = next(w for w in cua('list_windows', pid=args.pid)['windows'] if w['window_id'] == args.window)
    home = next(w['name'] for w in current['workspaces'] if any(wi['id'] == args.window for wi in w['windows']))
    expected = dict(zip(('x', 'y', 'width', 'height'), frame))
    row = {'label': label, 'actual': actual['bounds'], 'expected': expected, 'workspace': home, 'eui': eui()}
    row['pass'] = home == workspace and row['eui'] == 'on' and all(abs(actual['bounds'][k] - v) <= 2 for k, v in expected.items())
    result['rows'].append(row)
    if not row['pass']:
        raise AssertionError(row)


try:
    assert any(w['window_id'] == args.window for w in cua('list_windows', pid=args.pid)['windows']), 'PID does not own the spare window'
    move(args.left)
    check('initial-left', args.left, args.left_frame)
    move(args.right)
    check('workspace-right', args.right, args.right_frame)
    for repeat in range(3):
        for direction, workspace, frame in (('left', args.left, args.left_frame), ('right', args.right, args.right_frame)):
            run('kosmos', 'move-node-to-monitor', '--window-id', str(args.window), '--focus-follows-window', direction)
            check(f'{direction}-{repeat}', workspace, frame)
    move(args.left)
    time.sleep(.03)
    move(args.right)
    time.sleep(.03)
    move(args.left)
    check('rapid-left-right-left', args.left, args.left_frame)
except BaseException as error:
    result['error'] = repr(error)
finally:
    cleanup_errors = []

    def cleanup(action):
        try:
            action()
        except BaseException as error:
            cleanup_errors.append(repr(error))

    cleanup(lambda: run('kosmos', 'move-node-to-workspace', '--window-id', str(args.window), 'agent'))
    for workspace in start['workspaces']:
        if workspace['shown']:
            cleanup(lambda name=workspace['name']: run('kosmos', 'workspace', name))
    cleanup(lambda: run('kosmos', 'workspace', start['focused']['workspace']))

    def verify_restored():
        result['restored'] = state()
        assert result['restored']['focused'] == start['focused']
        assert {w['name'] for w in result['restored']['workspaces'] if w['shown']} == {w['name'] for w in start['workspaces'] if w['shown']}

    cleanup(verify_restored)

    def restore_eui():
        if eui() != 'on':
            cleanup_errors.append('Enhanced UI was not restored by Kosmos; independent restoration required')
            run(str(probe), 'eui-restore', str(args.pid))
        assert eui() == 'on'

    cleanup(restore_eui)
    cleanup(lambda: cua('end_session'))
    result['cleanup_error'] = cleanup_errors or None
    args.output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({k: result[k] for k in ('version', 'rows', 'error', 'cleanup_error')}, indent=2))
raise SystemExit(1 if result['error'] or result['cleanup_error'] else 0)

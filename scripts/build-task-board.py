#!/usr/bin/env python3
"""Build an offline HTML task board from its repository plan snapshot."""
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
folder = root / 'docs/board'
plan = json.loads((folder / 'plan.json').read_text())
ids = [task['id'] for task in plan['tasks']]
assert len(ids) == len(set(ids)), 'Duplicate task IDs'
phases = {phase['id'] for phase in plan['phases']}
tasks = {task['id']: task for task in plan['tasks']}
owners = {owner['id'] for owner in plan['owners']}
assert len(owners) == len(plan['owners']), 'Duplicate owner IDs'
for task in tasks.values():
    assert task['phase'] in phases, task['id']
    assert task['owner'] in owners, task['id']
    assert task['status'] in {'ready', 'todo', 'later', 'doing', 'review', 'done'}, task['id']
    assert task['steps'] and task['acceptance'] and task['deliverables'], task['id']
    assert all(item in tasks for item in task['dependencies']), task['id']
    if task['status'] == 'ready':
        assert all(tasks[item]['status'] == 'done' for item in task['dependencies']), task['id']
    for evidence in task['evidence']:
        assert evidence['href'].startswith('../'), 'Evidence must be a repository-relative link'
        assert (folder / evidence['href']).is_file(), evidence['href']
visited = set()
def visit(task_id, path):
    assert task_id not in path, f'Dependency cycle: {path + [task_id]}'
    if task_id in visited:
        return
    for dependency in tasks[task_id]['dependencies']:
        visit(dependency, path + [task_id])
    visited.add(task_id)
for task_id in tasks:
    visit(task_id, [])
assert plan['nextTask'] in tasks
source = (folder / 'template.html').read_text()
assert source.count('__PLAN_DATA__') == 1
payload = json.dumps(plan, ensure_ascii=False, separators=(',', ':')).replace('</', '<\\/')
output = folder / 'index.html'
output.write_text(source.replace('__PLAN_DATA__', payload))
print(f'Built {output}: {len(tasks)} tasks, {len(phases)} phases, dependencies checked')

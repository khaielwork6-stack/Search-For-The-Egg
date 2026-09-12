from pathlib import Path
import csv
import json
import re
import sys

PACK = Path(__file__).resolve().parents[1]

required = [
    'FINAL_GDD.pdf', 'MASTER_SPEC.md', 'SYSTEM_CONFIG.json', 'ECONOMY_TABLES.csv',
    'DATASTORE_SCHEMA.md', 'STATE_MACHINES.md', 'TEST_PLAN.md', 'ASSUMPTIONS.md',
    'START_HERE.md',
]
prompts = [
    'PHASE_1_ARCHITECTURE.md', 'PHASE_2_VERTICAL_SLICE.md',
    'PHASE_3_PROGRESSION_TOOLS.md', 'PHASE_4_LOBBY_META.md',
    'PHASE_5_HARD_BASEMENT_MONETIZATION.md', 'PHASE_6_RELEASE_QA.md',
]
errors = []

for name in required:
    if not (PACK / name).is_file():
        errors.append(f'missing {name}')
for name in prompts:
    if not (PACK / 'PHASE_PROMPTS' / name).is_file():
        errors.append(f'missing PHASE_PROMPTS/{name}')

cfg = json.loads((PACK / 'SYSTEM_CONFIG.json').read_text(encoding='utf-8'))

def weight_total(items):
    return round(sum(float(item['weight']) for item in items), 8)

if weight_total(cfg['classes']['weights']) != 100:
    errors.append('class weights do not total 100')
if weight_total(cfg['monetization']['eventChest']['rewards']) != 100:
    errors.append('event chest weights do not total 100')

ids = [item['id'] for item in cfg['classes']['weights']]
if len(ids) != len(set(ids)):
    errors.append('duplicate class IDs')

for family_name, family in cfg['toolUpgrades'].items():
    for path_name, levels in family.items():
        if path_name == 'evidence':
            continue
        expected = list(range(len(levels)))
        got = [item['level'] for item in levels]
        if got != expected:
            errors.append(f'non-contiguous levels: {family_name}.{path_name}: {got}')
        if levels[-1].get('nextCash') is not None:
            errors.append(f'last level must have null nextCash: {family_name}.{path_name}')

rows = list(csv.DictReader((PACK / 'ECONOMY_TABLES.csv').open(encoding='utf-8', newline='')))
daily_csv = {int(r['level']): int(r['value']) for r in rows if r['table'] == 'daily'}
daily_json = {int(r['day']): int(r['gems']) for r in cfg['dailyRewards']}
if daily_csv != daily_json:
    errors.append(f'daily rewards disagree: csv={daily_csv}, json={daily_json}')

class_csv = {r['id']: float(r['value']) for r in rows if r['table'] == 'class'}
class_json = {r['id']: float(r['weight']) for r in cfg['classes']['weights']}
if class_csv != class_json:
    errors.append('class weights disagree between CSV and JSON')

mandatory = [
    'Inspect', 'complete build pack', 'only Phase', 'server-authoritative',
    'automated', 'Roblox Studio', 'concrete', 'Update', 'Commit', 'Stop'
]
for name in prompts:
    text = (PACK / 'PHASE_PROMPTS' / name).read_text(encoding='utf-8')
    for term in mandatory:
        if term.lower() not in text.lower():
            errors.append(f'{name} missing workflow concept: {term}')

all_primary = '\n'.join((PACK / p).read_text(encoding='utf-8') for p in [
    'MASTER_SPEC.md', 'DATASTORE_SCHEMA.md', 'STATE_MACHINES.md',
    'TEST_PLAN.md', 'ASSUMPTIONS.md', 'START_HERE.md'
])
if 'ASSUMED' not in all_primary:
    errors.append('assumption label missing from primary docs')

if errors:
    print('BUILD PACK INVALID')
    for err in errors:
        print('-', err)
    sys.exit(1)

print('BUILD PACK VALID')
print(f'required_files={len(required)} phase_prompts={len(prompts)} economy_rows={len(rows)}')
print('class_weight_total=100 event_chest_weight_total=100')

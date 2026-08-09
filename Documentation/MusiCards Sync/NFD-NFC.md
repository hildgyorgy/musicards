1. script: NFD -> NFC normalizálás

ssh umbrel@umbrel.local 'python3 -' <<'PY'
import os
import unicodedata
from collections import defaultdict

MUSIC = "/home/umbrel/umbrel/home/Music"
WANTED = "Nyeső Mária"

# A mappát Unicode-logikával keressük meg, nem byte-pontos névvel.
matches = [
    name for name in os.listdir(MUSIC)
    if unicodedata.normalize("NFC", name) == WANTED
]

if len(matches) != 1:
    raise SystemExit(f"STOP: {len(matches)} megfelelő Nyeső Mária mappát találtam.")

root = os.path.join(MUSIC, matches[0])

files = []
dirs = []
collisions = []

# Előzetes teljes audit
for dirpath, dirnames, filenames in os.walk(root):
    groups = defaultdict(list)

    for name in dirnames + filenames:
        groups[unicodedata.normalize("NFC", name)].append(name)

    for normalized, originals in groups.items():
        if len(originals) > 1:
            collisions.append((dirpath, normalized, originals))

    for name in filenames:
        if not unicodedata.is_normalized("NFC", name):
            files.append(os.path.join(dirpath, name))

    for name in dirnames:
        if not unicodedata.is_normalized("NFC", name):
            dirs.append(os.path.join(dirpath, name))

if collisions:
    print("STOP — NFC collision található.")
    for item in collisions:
        print(item)
    raise SystemExit(1)

print(f"Fájlok átnevezése: {len(files)}")
print(f"Almappák átnevezése: {len(dirs)}")

# Fájlok
for old in files:
    parent = os.path.dirname(old)
    new = os.path.join(
        parent,
        unicodedata.normalize("NFC", os.path.basename(old))
    )
    print("FILE:", repr(old), "→", repr(new))
    os.rename(old, new)

# Almappák: legmélyebbről felfelé
dirs.sort(key=lambda p: p.count(os.sep), reverse=True)

for old in dirs:
    parent = os.path.dirname(old)
    new = os.path.join(
        parent,
        unicodedata.normalize("NFC", os.path.basename(old))
    )
    print("DIR :", repr(old), "→", repr(new))
    os.rename(old, new)

# Végül maga az előadó-mappa
current_root = root
root_name = os.path.basename(current_root)
nfc_root_name = unicodedata.normalize("NFC", root_name)

if root_name != nfc_root_name:
    new_root = os.path.join(MUSIC, nfc_root_name)
    print("ROOT:", repr(current_root), "→", repr(new_root))
    os.rename(current_root, new_root)

print()
print("✓ Nyeső Mária migráció kész.")
PY


2. script: NFD maradvány ellenőrzés

ssh umbrel@umbrel.local 'python3 - <<'"'"'PY'"'"'
import os, unicodedata

root="/home/umbrel/umbrel/home/Music/Nyeső Mária"
bad=[]

for dirpath, dirnames, filenames in os.walk(root):
    for name in dirnames + filenames:
        if not unicodedata.is_normalized("NFC", name):
            bad.append(os.path.join(dirpath, name))

print("Nem-NFC elemek:", len(bad))

for path in bad[:20]:
    print(repr(path))
PY'

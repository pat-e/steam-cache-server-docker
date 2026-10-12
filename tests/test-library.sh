#!/bin/sh
# shellcheck disable=SC2319 # "[ ... ]; ok $?" deliberately passes the test result
set -u
# Offline tests for the library-registration logic and startapp.sh (fake Steam).
# Run: sh tests/test-library.sh   (needs dash, awk, sed, od)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=$ROOT/rootfs/usr/local/bin
export PATH="$BIN:$PATH"
T=$(mktemp -d); cd "$T" || exit 1; pass=0; fail=0
ok() { if [ "$1" = 0 ]; then pass=$((pass+1)); echo "PASS $2"; else fail=$((fail+1)); echo "FAIL $2"; fi; }
reg() { dash "$BIN/steam-library-register" "$@" 2>/dev/null; }
idx() { awk '/^\t"[0-9]+"$/{gsub(/[\t"]/,"");printf "%s ",$0}' "$1"; }
R=$T/steam; mkdir -p "$R" g1 g2 "g 4"; V=$R/steamapps/libraryfolders.vdf
reg "$R" "$T/g1" NAS; ok $? "fresh: rc 0"
[ "$(idx "$V")" = "0 1 " ]; ok $? "fresh: indices 0 1"
id1=$(sed -n 's/.*"contentid"[^"]*"\([0-9]*\)".*/\1/p' g1/libraryfolder.vdf); grep -q "\"contentid\"		\"$id1\"" "$V"; ok $? "fresh: contentid matches marker"
a=$(md5sum <"$V"); reg "$R" "$T/g1/" NAS; r=$?; b=$(md5sum <"$V"); [ $r = 0 ] && [ "$a" = "$b" ]; ok $? "idempotent rerun (trailing slash): unchanged"
printf '"libraryfolder"\n{\n\t"contentid"\t\t"424242"\n\t"label"\t\t"Old"\n}\n' > g2/libraryfolder.vdf
reg "$R" "$T/g2"; reg "$R" "$T/g 4"; [ "$(idx "$V")" = "0 1 2 3 " ]; ok $? "multiple paths: indices 0..3"
grep -q '"contentid"		"424242"' "$V" && grep -q '"label"		"Old"' "$V"; ok $? "existing marker contentid+label reused"
# Collision / gaps
R2=$T/steam2; mkdir -p "$R2/steamapps" g5; V2=$R2/steamapps/libraryfolders.vdf
printf '"libraryfolders"\n{\n\t"contentstatsid"\t\t"-1"\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t\t"apps"\n\t\t{\n\t\t\t"228980"\t\t"1"\n\t\t}\n\t}\n\t"3"\n\t{\n\t\t"path"\t\t"/mnt/other/"\n\t\t"apps"\n\t\t{\n\t\t}\n\t}\n}\n' "$R2" > "$V2"
reg "$R2" "$T/g5"; [ "$(idx "$V2")" = "0 3 4 " ]; ok $? "index collision/gap: new entry gets 4"
grep -q '"228980"		"1"' "$V2"; ok $? "existing apps preserved"
reg "$R2" /mnt/other; ok $? "listed-but-unmounted path counts as registered (rc 0)"
reg "$R2" /nonexistent; [ $? = 2 ]; ok $? "missing path -> rc 2"
reg "$R2" relative; [ $? = 1 ]; ok $? "relative path rejected"
reg "$R2" "$T/a\"b"; [ $? = 1 ]; ok $? "quote rejected"
R3=$T/steam3; mkdir -p "$R3/steamapps" g6; printf '"libraryfolders"\n{\n' > "$R3/steamapps/libraryfolders.vdf"
reg "$R3" "$T/g6"; [ $? = 1 ] && [ ! -e g6/libraryfolder.vdf ] && [ "$(wc -l < "$R3/steamapps/libraryfolders.vdf")" = 2 ]; ok $? "malformed vdf: untouched, no marker written"

# ---- startapp.sh end-to-end with a fake steam ----
S=$T/startapp.sh; sed "s#/usr/bin/steam#$T/fakesteam#" "$ROOT/rootfs/startapp.sh" > "$S"
printf '#!/bin/sh\necho "FAKESTEAM $*"\n' > fakesteam; chmod +x fakesteam
C=$T/config; mkdir -p "$C" lib1 lib2 lib3
run() { env -i PATH="$BIN:/usr/bin:/bin" HOME="$C" XDG_RUNTIME_DIR="$T/run" STEAM_GUI_FOCUS_NOTICE=0 STEAM_GUI_STATE_DIR="$C/.steam-gui" "$@" dash "$S" 2>&1; }
out=$(run STEAM_LIBRARY_PATHS="$T/lib1"); echo "$out" | grep -q "not installed in /config yet" && [ ! -e "$C/xdg/data/Steam/steamapps" ]; ok $? "startapp fresh /config: registration deferred, nothing written"
echo "$out" | grep -q "FAKESTEAM -nofriendsui -cef-disable-gpu -cef-disable-gpu-compositing"; ok $? "startapp execs steam with flags"
out=$(run); echo "$out" | grep -q "steam-library\|not installed"; [ $? = 1 ]; ok $? "startapp with no library env: no library action"
mkdir -p "$C/xdg/data/Steam" "$C/.steam"; touch "$C/xdg/data/Steam/steam.sh"; ln -s "$C/xdg/data/Steam" "$C/.steam/root"
out=$(run STEAM_LIBRARY_PATHS=" $T/lib1 , $T/lib2,"); CV=$C/xdg/data/Steam/steamapps/libraryfolders.vdf
[ "$(idx "$CV")" = "0 1 2 " ]; ok $? "startapp env list (spaces, trailing comma): 2 libs registered"
a=$(md5sum <"$CV"); run STEAM_LIBRARY_PATHS="$T/lib1,$T/lib2" >/dev/null; [ "$a" = "$(md5sum <"$CV")" ]; ok $? "startapp rerun: vdf unchanged"
out=$(env -i PATH="$BIN:/usr/bin:/bin" STEAM_GUI_STATE_DIR="$C/.steam-gui" dash "$BIN/add-steam-library" "$T/lib3" "Lib Three" 2>&1); echo "$out" | grep -q "Queued"; ok $? "add-steam-library queues"
env -i PATH="$BIN:/usr/bin:/bin" STEAM_GUI_STATE_DIR="$C/.steam-gui" dash "$BIN/add-steam-library" "$T/lib3" | grep -q "already queued"; ok $? "add-steam-library dedupes queue"
env -i PATH="$BIN:/usr/bin:/bin" STEAM_GUI_STATE_DIR="$C/.steam-gui" dash "$BIN/add-steam-library" /nope >/dev/null 2>&1; [ $? = 1 ]; ok $? "add-steam-library rejects missing path"
printf '%s\t%s\n' "/mnt/notyet" "Later" >> "$C/.steam-gui/pending-libraries"
run >/dev/null; [ "$(idx "$CV")" = "0 1 2 3 " ] && grep -q '"label"		"Lib Three"' "$CV"; ok $? "startapp applies pending entry"
[ "$(cat "$C/.steam-gui/pending-libraries")" = "$(printf '/mnt/notyet\tLater')" ]; ok $? "unmounted pending entry kept for retry, applied one removed"
out=$(run STEAM_GPU=on); echo "$out" | grep -q "FAKESTEAM -nofriendsui *$"; ok $? "STEAM_GPU=on: no -cef-disable-gpu flags"
if ls /dev/dri/renderD* >/dev/null 2>&1; then echo "SKIP auto-detect test (box has a render node)"; else
out=$(run); echo "$out" | grep -q "No usable GPU" && echo "$out" | grep -q "FAKESTEAM -nofriendsui -cef-disable-gpu -cef-disable-gpu-compositing"; ok $? "STEAM_GPU=auto without /dev/dri: software mode + CEF flags"; fi
out=$(run STEAM_EXTRA_ARGS="-no-cef-sandbox"); echo "$out" | grep -q "FAKESTEAM .*-no-cef-sandbox"; ok $? "STEAM_EXTRA_ARGS passed through"
echo "pass=$pass fail=$fail"; rm -rf "$T"

#!/usr/bin/env python3
"""
Make compile_commands.json cover the files you actually open.

`bear parse-sh` reads theos's dry run, so it records the files theos compiles,
and for a Logos source that is not the file in your editor: theos preprocesses
src/Features/Feed/FBPFeedHooks.xm into .theos/obj/…/FBPFeedHooks.xm.mm and
compiles that. clangd looks up the path of the buffer you opened, finds no
entry, falls back to guessing, and every Foundation type turns red.

Three passes:

  1. Every generated .xm.mm / .x.m entry gains a twin pointing at the real
     source under src/, with the same flags. The generated entries are kept, so
     stepping into preprocessed code still works.
  2. Every remaining .h / .m / .mm / .xm under src/ and FBPNotifyBridge/src/
     gains an entry copied from a template, so a header opened on its own gets
     the real SDK and include flags instead of clangd's guess.
  3. -ferror-limit=0 is added everywhere, so clangd keeps reporting past the
     twentieth error in a file it is still indexing.

Stale entries whose source no longer exists are dropped, and every path is made
absolute so the database works whatever directory clangd starts in.

What this does not fix, and cannot: clang still cannot parse `%hook`, `%group`,
`%end` or a Logos method body, so a raw .xm keeps reporting "expected
unqualified-id" and "missing context for method declaration" on those lines.
That is what the Suppress list in .clangd is for, and it is why the list exists
rather than being an oversight. Type lookup is what the entry buys you: with the
right flags an .xm resolves NSString and every Facebook class, and without them
nothing in the file resolves at all. If you ever see "unknown type name" in an
.xm, the flags are wrong and this script is the place to look.

Run by `make compile-commands`; safe to run on its own at any time.
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(ROOT, "compile_commands.json")

# .theos/obj/debug/arm64/src/Features/Feed/FBPFeedHooks.xm.mm -> src/.../FBPFeedHooks.xm
# The number of directories between obj/ and the source varies with the build
# (debug adds one), so match them loosely rather than counting.
GENERATED = re.compile(r"/\.theos/obj/(?:[^/]+/)*((?:src|FBPNotifyBridge)/.+?\.(?:xm|x))\.(?:mm|m)$")

HEADER_ROOTS = (
    os.path.join(ROOT, "src"),
    os.path.join(ROOT, "FBPNotifyBridge", "src"),
)
INDEXABLE = (".h", ".m", ".mm", ".xm", ".x", ".c")
SKIP_DIRS = {".theos", ".git", ".temp", "packages", "venv", "__pycache__"}


def absolute(path, directory):
    if os.path.isabs(path):
        return os.path.normpath(path)
    return os.path.normpath(os.path.join(directory, path))


def retarget(args, old_file, new_file, language="objective-c++"):
    """Point a recorded compile at a different source file.

    The source is *not* the last argument: theos ends every command with
    `-o <object>`, so swapping the last element silently leaves the original
    source in place and redirects the output on top of the new file instead.
    This finds the real source argument, drops the -o pair that a syntax-only
    lookup has no use for, and pins the language, which clangd otherwise
    guesses wrong for a bare .h or an unknown .xm.
    """
    out = []
    skip_next = False
    replaced = False
    for arg in args:
        if skip_next:
            skip_next = False
            continue
        if arg == "-o":
            skip_next = True
            continue
        if arg == "-x":
            skip_next = True
            continue
        if arg.startswith("-x") and len(arg) > 2:
            continue
        if arg == "-c":
            continue
        if not replaced and (arg == old_file or os.path.basename(arg) == os.path.basename(old_file)):
            replaced = True
            continue
        out.append(arg)
    if "-ferror-limit=0" not in out:
        out.append("-ferror-limit=0")
    out += ["-x", language, new_file]
    return out


def main():
    if not os.path.exists(DB):
        print(f"    error: {os.path.basename(DB)} not found — run `make compile-commands`.",
              file=sys.stderr)
        return 1

    with open(DB, encoding="utf-8") as f:
        try:
            entries = json.load(f)
        except Exception as exc:
            print(f"    error: {os.path.basename(DB)} is not valid JSON: {exc}", file=sys.stderr)
            return 1

    if not isinstance(entries, list):
        print(f"    error: {os.path.basename(DB)} should hold a list.", file=sys.stderr)
        return 1

    out = []
    seen = set()
    template = None
    mapped = []
    dropped = 0

    # --- pass 1: keep what bear found, and twin the Logos sources ------------
    for entry in entries:
        directory = absolute(entry.get("directory", ROOT), ROOT)
        path = absolute(entry.get("file", ""), directory)
        entry["directory"] = directory
        entry["file"] = path
        if template is None and entry.get("arguments"):
            template = entry

        # A generated Logos file normally does not exist on disk: the target
        # runs `make clean` before `make -n`, so bear records compiles that
        # were only ever described. Its original under src/ is what matters,
        # and the entry for the generated path is kept only if it is really
        # there, from an earlier build.
        m = GENERATED.search(path)
        if m:
            original = os.path.join(ROOT, m.group(1))
            if os.path.exists(original) and original not in seen:
                twin = dict(entry)
                twin["file"] = original
                twin.pop("command", None)
                twin["arguments"] = retarget(
                    entry.get("arguments", []), path, original,
                    "objective-c++" if original.endswith(".xm") else "objective-c")
                out.append(twin)
                seen.add(original)
                mapped.append(original)
            elif not os.path.exists(original):
                print(f"    warning: {os.path.relpath(path, ROOT)} maps to "
                      f"{os.path.relpath(original, ROOT)}, which is missing.",
                      file=sys.stderr)
            if not os.path.exists(path):
                continue
        elif not os.path.exists(path):
            dropped += 1
            continue

        if path not in seen:
            out.append(entry)
            seen.add(path)

    # --- pass 2: give every other source and header the same flags ----------
    added_headers = 0
    if template:
        for base in HEADER_ROOTS:
            if not os.path.isdir(base):
                continue
            for dirpath, dirnames, filenames in os.walk(base):
                dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
                for name in sorted(filenames):
                    if not name.endswith(INDEXABLE):
                        continue
                    path = os.path.join(dirpath, name)
                    if path in seen:
                        continue
                    entry = dict(template)
                    entry["file"] = path
                    entry.pop("command", None)
                    entry["arguments"] = retarget(
                        template.get("arguments", []), template["file"], path,
                        "c" if name.endswith(".c") else
                        "objective-c" if name.endswith(".m") else "objective-c++")
                    out.append(entry)
                    seen.add(path)
                    added_headers += 1
    elif entries:
        print("    warning: no entry carried an argument list, so headers were "
              "left out. Is bear's output what it used to be?", file=sys.stderr)

    # --- pass 3: let clangd report past its default error limit -------------
    # Appended, never inserted: the command ends with `-o <object>`, and a flag
    # dropped between those two would make the object file the output name.
    for entry in out:
        args = entry.get("arguments")
        if args is not None and "-ferror-limit=0" not in args:
            args.append("-ferror-limit=0")

    with open(DB, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)
        f.write("\n")

    note = f"    Indexed {len(out)} files in compile_commands.json"
    note += f" — {len(mapped)} Logos source(s) mapped"
    if added_headers:
        note += f", {added_headers} header/source entr{'y' if added_headers == 1 else 'ies'} added"
    if dropped:
        note += f", {dropped} stale dropped"
    print(note)
    for path in mapped:
        print(f"      + {os.path.relpath(path, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

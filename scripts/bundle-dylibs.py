#!/usr/bin/env python3
"""Copies the Homebrew dylibs a binary needs (recursively) into a Frameworks folder and rewrites every load path to
@rpath/<name>, so the binary runs on a Mac without Homebrew.
Usage: bundle-dylibs.py <binary> <frameworks-dir>   (the binary gets an rpath to the folder, relative to itself)"""
import os, shutil, subprocess, sys

binary, frameworks = sys.argv[1], sys.argv[2]
os.makedirs(frameworks, exist_ok=True)

def deps(path):
    lines = subprocess.run(["otool", "-L", path], capture_output=True, text=True, check=True).stdout.splitlines()[1:]
    return [l.strip().split(" (")[0] for l in lines]

def external(dep):
    return dep.startswith("/opt/homebrew/") or dep.startswith("/usr/local/")

copied = {}   # basename -> bundled path
todo = [binary]
while todo:
    current = todo.pop()
    for dep in deps(current):
        if not external(dep):
            continue
        name = os.path.basename(dep)
        if name not in copied:
            target = os.path.join(frameworks, name)
            shutil.copyfile(os.path.realpath(dep), target)
            os.chmod(target, 0o755)
            copied[name] = target
            todo.append(target)

# sdl2-compat loads SDL3 with dlopen at runtime, so otool cannot see it
for extra in ["/opt/homebrew/opt/sdl3/lib/libSDL3.0.dylib"]:
    if os.path.exists(extra) and "libSDL2-2.0.0.dylib" in copied:
        name = os.path.basename(extra)
        shutil.copyfile(os.path.realpath(extra), os.path.join(frameworks, name))
        os.chmod(os.path.join(frameworks, name), 0o755)
        copied[name] = os.path.join(frameworks, name)

def rewrite(path, is_lib):
    args = []
    for dep in deps(path):
        if external(dep) and os.path.basename(dep) in copied:
            args += ["-change", dep, "@rpath/" + os.path.basename(dep)]
    if is_lib:
        args += ["-id", "@rpath/" + os.path.basename(path)]
    if args:
        subprocess.run(["install_name_tool", *args, path], check=True, capture_output=True)

for path in copied.values():
    rewrite(path, True)
    subprocess.run(["install_name_tool", "-add_rpath", "@loader_path", path], capture_output=True)
rewrite(binary, False)
relative = os.path.relpath(frameworks, os.path.dirname(binary))
subprocess.run(["install_name_tool", "-add_rpath", "@executable_path/" + relative, binary], capture_output=True)

# install_name_tool invalidates signatures; ad-hoc sign everything again
for path in [*copied.values(), binary]:
    subprocess.run(["codesign", "--force", "--sign", "-", path], check=True, capture_output=True)
print(f"bundled {len(copied)} dylibs into {frameworks}")

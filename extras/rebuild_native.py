"""Plan or rebuild a Windows native module from a Time Busters source package."""

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import types


GAME_UNITS = (
    "heightfield", "lit_actors", "lit_hud", "lit_logic", "lit_overlay", "lit_save", "lit_world",
    "pad", "sfx", "tb_collision", "tb_entities", "tb_fx", "tb_hud", "tb_menu", "tb_mover",
    "tb_path", "tb_save", "tb_shadow", "tb_shapes", "tb_steer", "tb_sweep", "tb_world",
)
COMPILE_FLAGS = ("-g", "-std=gnu++26")
BRIDGE_DEFINES = (
    "DEBUG_ENABLED", "DEBUG_METHODS_ENABLED", "GDEXTENSION", "HOT_RELOAD_ENABLED",
    "NOMINMAX", "THREADS_ENABLED", "WIN32_LEAN_AND_MEAN", "WINDOWS_ENABLED",
    "tb_reference_EXPORTS",
)
WINDOWS_LIBRARIES = (
    "bcrypt", "kernel32", "user32", "gdi32", "winspool", "shell32", "ole32",
    "oleaut32", "uuid", "comdlg32", "advapi32",
)
OWNER_PATH = "tests/native_audio/owned_process_v5.py"
TOOLCHAIN_PATH = "tools/toolchain.json"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def member(value):
    name = PurePosixPath(value)
    require(name.parts and not name.is_absolute() and ".." not in name.parts
            and name.as_posix() == value and not re.search(r'[:\\\x00-\x1f]', value),
            f"Expected a package-relative path, got {value!r}")
    return name


def package_file(root, name):
    path = root.joinpath(*member(name).parts)
    resolved = path.resolve(strict=True)
    require(resolved == path and resolved.is_relative_to(root) and resolved.is_file(),
            f"Expected a regular file inside the source package: {name}")
    return resolved


def output_directory(source, supplied, toolchain):
    require(not os.path.lexists(supplied), "Choose a new output directory")
    output = supplied.absolute().resolve()
    require(not output.is_relative_to(source) and not source.is_relative_to(output),
            "The output and source package must be separate directories")
    require(not output.is_relative_to(toolchain) and not toolchain.is_relative_to(output),
            "The output and compiler must be separate directories")
    return output


def source_inventory(root, selected, partial):
    manifest_path = package_file(root, "source-manifest.json")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    pins = manifest["files"]
    require(isinstance(pins, dict) and pins, "The source manifest has no files")
    inputs, changed = {}, []
    selected_paths = {f"native/reference/engine/game/src/{unit}.cpp" for unit in selected}
    for name, expected in pins.items():
        member(name)
        if not (name.startswith("native/") or name in (OWNER_PATH, TOOLCHAIN_PATH)):
            continue
        path = package_file(root, name)
        digest = sha(path)
        inputs[name] = {"sha256": digest, "bytes": path.stat().st_size}
        if digest == expected["sha256"] and path.stat().st_size == expected["bytes"]:
            continue
        editable = name.startswith(("native/reference/", "native/bridge/"))
        require(editable and path.suffix in (".cpp", ".h", ".hpp"),
                f"A packaged library, SDK or build tool changed: {name}")
        if path.suffix == ".cpp":
            require(name in selected_paths or name == "native/bridge/reference_bridge.cpp",
                    f"Changed source is outside this rebuild; select it with --unit: {name}")
        else:
            require(not partial, "A header changed; omit --unit to rebuild all game units")
            require(name.startswith(("native/reference/engine/game/", "native/bridge/")),
                    "A core or audio header changed; rebuild its library before using this helper")
        changed.append({"path": name, "original_sha256": expected["sha256"], "sha256": digest})

    required = selected_paths | {
        "native/bridge/reference_bridge.cpp", "native/libraries/libref_game.a",
        "native/libraries/libref_core.a", "native/libraries/libref_codec.a",
        "native/libraries/libref_stb.a", "native/sdk/lib/libgodot-cpp.a", OWNER_PATH, TOOLCHAIN_PATH,
    }
    require(required <= inputs.keys(), "The source package is missing native build inputs")
    toolchain = json.loads(package_file(root, TOOLCHAIN_PATH).read_text(encoding="utf-8"))
    owner = package_file(root, OWNER_PATH).read_bytes()
    return manifest, inputs, changed, toolchain, owner


def build_plan(args):
    root = args.source_root.resolve(strict=True)
    require(root.is_dir(), "Expected an extracted source package")
    toolchain_root = args.toolchain.resolve(strict=True)
    compiler_directory = toolchain_root / "bin" if (toolchain_root / "bin").is_dir() else toolchain_root
    compiler = compiler_directory / "x86_64-w64-mingw32-clang++.exe"
    archiver = compiler_directory / "x86_64-w64-mingw32-llvm-ar.exe"
    require(compiler.is_file() and archiver.is_file(), "Expected the LLVM-MinGW x64 compiler and archiver")
    output = output_directory(root, args.output, toolchain_root)
    selected = tuple(dict.fromkeys(args.unit or GAME_UNITS))
    require(all(re.fullmatch(r"[a-z][a-z0-9_]*", unit) for unit in selected),
            "Use game-unit names such as tb_steer")
    manifest, inputs, changed, toolchain, owner = source_inventory(root, selected, bool(args.unit))
    include_directories = [root / f"native/reference/engine/{name}/include"
                           for name in ("game", "core", "audio")]
    bridge_directories = include_directories + [
        root / "native/bridge", root / "native/sdk/godot-cpp/include",
        root / "native/sdk/godot-cpp/gdextension", root / "native/sdk/generated/include",
        root / "native/reference/third_party/stb",
    ]
    require(all(path.resolve(strict=True) == path and path.is_dir() for path in bridge_directories),
            "The extracted source package is missing include directories")
    commands = {
        "compiler_version": [str(compiler), "--version"],
        "archive_before": [str(archiver), "t", str(root / "native/libraries/libref_game.a")],
    }
    for unit in selected:
        commands[f"compile_{unit}"] = [str(compiler)] + [f"-I{path}" for path in include_directories] + [
            *COMPILE_FLAGS, "-o", str(output / f"objects/{unit}.cpp.obj"), "-c",
            str(root / f"native/reference/engine/game/src/{unit}.cpp"),
        ]
    commands["compile_bridge"] = [str(compiler)] + [f"-I{path}" for path in bridge_directories] + [
        *[f"-D{define}" for define in BRIDGE_DEFINES], *COMPILE_FLAGS,
        "-o", str(output / "reference_bridge.cpp.obj"), "-c", str(root / "native/bridge/reference_bridge.cpp"),
    ]
    commands["archive_replace"] = [str(archiver), "rcs", str(output / "libref_game.a")] + [
        str(output / f"objects/{unit}.cpp.obj") for unit in selected
    ]
    commands["archive_after"] = [str(archiver), "t", str(output / "libref_game.a")]
    for unit in selected:
        commands[f"readback_{unit}"] = [str(archiver), "p", str(output / "libref_game.a"), f"{unit}.cpp.obj"]
    commands["link"] = [str(compiler), "-g", "-shared", "-static", "-static-libgcc", "-static-libstdc++",
        "-Wl,--no-undefined", "-Wl,--gc-sections", f"-Wl,-Map,{output / 'native-link.map'}",
        "-o", str(output / "tb_reference.dll"), str(output / "reference_bridge.cpp.obj"),
        str(output / "libref_game.a"), str(root / "native/libraries/libref_codec.a"),
        str(root / "native/libraries/libref_core.a"), str(root / "native/libraries/libref_stb.a"),
        str(root / "native/sdk/lib/libgodot-cpp.a"), *[f"-l{name}" for name in WINDOWS_LIBRARIES],
    ]
    plan = {
        "source_root": str(root), "output": str(output), "source_commit": manifest["source_commit"],
        "source_manifest_sha256": sha(root / "source-manifest.json"), "game_units": list(selected),
        "partial_game_rebuild": bool(args.unit), "changed_sources": changed, "inputs": inputs,
        "compiler_sha256": sha(compiler), "archiver_sha256": sha(archiver),
        "expected_clang_version": toolchain["versions"]["clang"],
        "llvm_mingw_version": toolchain["versions"]["llvm_mingw"],
        "process_owner_sha256": hashlib.sha256(owner).hexdigest(), "commands": commands,
    }
    return plan, owner


def recheck_inputs(plan):
    root = Path(plan["source_root"])
    for name, pin in plan["inputs"].items():
        require(sha(package_file(root, name)) == pin["sha256"], f"Input changed during build: {name}")


def build(plan, owner_source, timeout):
    require(os.name == "nt", "The native build targets Windows x64")
    output = Path(plan["output"])
    output.mkdir(parents=True, exist_ok=False)
    for name in ("objects", "logs", "tmp"):
        (output / name).mkdir()
    write_json(output / "build-plan.json", plan)
    owner = types.ModuleType("timebusters_packaged_process_owner")
    exec(compile(owner_source, OWNER_PATH, "exec"), owner.__dict__)
    environment = os.environ | {"TMP": str(output / "tmp"), "TEMP": str(output / "tmp")}
    stages = []
    result = {"passed": False, "stages": stages, "build_plan_sha256": sha(output / "build-plan.json")}
    try:
        for name, command in plan["commands"].items():
            if name == "archive_replace":
                recheck_inputs(plan)
                shutil.copyfile(Path(plan["source_root"]) / "native/libraries/libref_game.a", output / "libref_game.a")
            log = output / f"logs/{name}.log"
            receipt = owner.run_owned(command, cwd=output, env=environment, log_path=log, timeout=timeout)
            write_json(output / f"logs/{name}.json", receipt)
            stages.append({"stage": name, "passed": receipt["passed"],
                           "receipt_sha256": sha(output / f"logs/{name}.json")})
            require(receipt["passed"], f"Build stage failed; inspect {log}")
            if name == "compiler_version":
                version = log.read_text(encoding="utf-8", errors="replace")
                require(re.search(r"clang version " + re.escape(plan["expected_clang_version"]) + r"\b", version),
                        "Compiler version differs from tools/toolchain.json in the source package")
            elif name == "archive_before":
                members = Counter(log.read_text(encoding="utf-8").splitlines())
                require(all(members[f"{unit}.cpp.obj"] == 1 for unit in plan["game_units"]),
                        "Expected exactly one archive member for each selected game unit")
            elif name == "archive_after":
                before = (output / "logs/archive_before.log").read_bytes()
                require(log.read_bytes() == before, "Replacing game objects changed the archive member list")
            elif name.startswith("readback_"):
                unit = name.removeprefix("readback_")
                require(sha(log) == sha(output / f"objects/{unit}.cpp.obj"), "Archived object differs from compiler output")
        recheck_inputs(plan)
        result.update(passed=True, native_module_sha256=sha(output / "tb_reference.dll"),
                      game_archive_sha256=sha(output / "libref_game.a"))
    except (OSError, ValueError) as exc:
        result["error"] = str(exc)
        raise
    finally:
        write_json(output / "build-result.json", result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--toolchain", type=Path, required=True, help="LLVM-MinGW root or bin directory")
    parser.add_argument("--output", type=Path, required=True, help="New build directory outside the source package")
    parser.add_argument("--unit", action="append", help="Recompile only a named game unit, for example tb_steer")
    parser.add_argument("--build", action="store_true", help="Compile and link; default prints a checked plan")
    parser.add_argument("--stage-timeout", type=int, default=180, help="Seconds per owned compiler or linker job")
    args = parser.parse_args()
    try:
        require(1 <= args.stage_timeout <= 1800, "Stage timeout must be between 1 and 1800 seconds")
        plan, owner = build_plan(args)
        result = build(plan, owner, args.stage_timeout) if args.build else plan
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return 0
    except (KeyError, OSError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

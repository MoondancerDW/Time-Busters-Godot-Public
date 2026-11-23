"""Copy and extend a compatible Time Busters project with the cosmetic loader."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import struct
import tempfile
import wave

HERE = Path(__file__).resolve().parent
ASSET_LIMIT = 8 * 1024 * 1024
MANIFEST_LIMIT = 65536
ARCA01_RU = "be56218eb50e87b07bf0e4ca19dc888dd7867ce2e09d5d8f5c8fdf03f643da0a"
SOURCE_HASH = re.compile(r"[0-9a-f]{64}")
WINDOWS_DEVICE_NAME = re.compile(r"(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?", re.IGNORECASE)
SOURCE_PINS = {
    "project.godot": "a016e90708204e7b1c17411a34023e98be845b4d364303d59f31e811c30dfa37",
    "reference/main.gd": "58da5769beecc90db060416e170fb2e6b9083bdf339435ed40d605b84a68321f",
    "reference/main.tscn": "4f3172ec67f09fa253bcb436133fd8e5959b16b7f57c62b2bbf927192d175ac6",
    "reference/native_audio.gd": "c47cf3da716ae10abcd1bc23ca4199f0e13191962285def44b0e5afb7e019ddf",
    "reference/checkpoint_store.gd": "a0813157600c092e405c0d5cc602052d9dbd1bcab2ddb2add6beff40cbcfd811",
    "reference/asset_layout.gd": "740a2f6fa7672b5a4fa7096504cdf91217ed95df877531835778e4b3972acbdb",
    "bin/tb_reference.dll": "8f293549dd9e7a49f0d9d98d867b09c7591c73cb763f4badda81fa06efd3d983",
}
BASE_PROFILE = "TimeBustersStandalone"
MOD_PROFILE = BASE_PROFILE + "-ModKit"
PROFILE_ANCHOR = f'config/custom_user_dir_name="{BASE_PROFILE}"'

MAIN_EDITS = (
    (
        'const NativeAudioScript = preload("res://reference/native_audio.gd")',
        'const NativeAudioScript = preload("res://reference/native_audio.gd")\n'
        'const CosmeticModScript = preload("res://reference/cosmetic_mods.gd")\nvar _cosmetic_mods = CosmeticModScript.new()',
    ),
    (
        "\t_native_audio = NativeAudioScript.new()",
        "\t_cosmetic_mods.configure()\n\t_native_audio = NativeAudioScript.new()\n\t_native_audio.cosmetic_mods = _cosmetic_mods",
    ),
    (
        "func _clear_world() -> void:\n",
        "func _clear_world() -> void:\n\t_cosmetic_mods.clear_models()\n",
    ),
    (
        "\tvar dark: float = clampf(float(frame.get(",
        "\t_cosmetic_mods.present_models(frame, scene_info, _actor_nodes, _actors, _session_generation)\n"
        "\tvar dark: float = clampf(float(frame.get(",
    ),
)
AUDIO_EDITS = (
    ("var _voices: Dictionary = {}", "var _voices: Dictionary = {}\nvar cosmetic_mods"),
    (
        "\t\t\tif enabled:\n\t\t\t\t_command(command)",
        '\t\t\tif enabled:\n\t\t\t\tvar audible: Dictionary = command\n'
        '\t\t\t\tif cosmetic_mods != null:\n'
        '\t\t\t\t\taudible = cosmetic_mods.sound_for(command, str(packet.get("resource_sha256", "")))\n'
        '\t\t\t\t_command(audible)',
    ),
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def integer(value, low, high):
    return type(value) is int and low <= value <= high


def asset(directory, relative, suffix):
    require(isinstance(relative, str) and re.fullmatch(r"[A-Za-z0-9_./ -]+", relative)
            and all(part.rstrip(" .") == part and part and not WINDOWS_DEVICE_NAME.fullmatch(part)
                    for part in relative.split("/")), "Use a safe relative asset path")
    entry = PurePosixPath(relative)
    require(entry.suffix == suffix, f"Expected {suffix} file")
    path = directory.joinpath(*entry.parts)
    require(path.resolve(strict=True).is_relative_to(directory) and path.is_file()
            and 0 < path.stat().st_size <= ASSET_LIMIT, f"Asset is missing or over the size limit: {path}")
    return path


def validate_glb(path):
    data = path.read_bytes()
    require(len(data) >= 20 and struct.unpack_from("<4sII", data) == (b"glTF", 2, len(data)), "Expected binary glTF 2.0")
    length, tag = struct.unpack_from("<I4s", data, 12)
    require(tag == b"JSON" and length <= len(data) - 20, "Invalid GLB JSON section")
    document = json.loads(data[20:20 + length])
    require(isinstance(document, dict), "Expected a GLB JSON object")
    for name in ("meshes", "scenes", "buffers", "images", "animations", "cameras", "skins", "extensionsRequired"):
        require(isinstance(document.get(name, []), list), f"Invalid GLB {name} array")
    require(document.get("meshes") and document.get("scenes") and not any(
        document.get(kind) for kind in ("animations", "cameras", "skins", "extensionsRequired")),
        "Expected a passive GLB scene with meshes")
    for entry in document.get("buffers", []) + document.get("images", []):
        uri = entry.get("uri", "data:") if isinstance(entry, dict) else None
        require(isinstance(uri, str) and uri.startswith("data:"), "Embed every GLB image and buffer")
    return len(document["meshes"])


def validate_wav(path):
    with wave.open(str(path), "rb") as sound:
        require(sound.getcomptype() == "NONE" and sound.getsampwidth() == 2 and sound.getnchannels() in (1, 2)
                and 8000 <= sound.getframerate() <= 192000 and sound.getnframes() > 0,
                "Expected uncompressed 16-bit WAV at 8–192 kHz, mono or stereo")
        frames = sound.getnframes()
        require(len(sound.readframes(frames)) == frames * sound.getnchannels() * 2, "Incomplete WAV frames")
        return frames


def validate(directory):
    directory = directory.resolve(strict=True)
    manifest = directory / "mod.json"
    require(manifest.is_file() and manifest.resolve(strict=True).is_relative_to(directory)
            and manifest.stat().st_size <= MANIFEST_LIMIT, "Missing, external or oversized mod.json")
    data = json.loads(manifest.read_text(encoding="utf-8"))
    require(isinstance(data, dict) and integer(data.get("schema_version"), 2, 2)
            and isinstance(data.get("name"), str) and data["name"].strip(), "Expected cosmetic schema version 2 and name")
    sources = {}
    seen = set()
    for group, verify in (("models", validate_glb), ("sounds", validate_wav)):
        rows = data.get(group, [])
        require(isinstance(rows, list) and len(rows) <= 64, f"Invalid {group} array")
        for row in rows:
            require(isinstance(row, dict) and isinstance(row.get("resource_sha256"), str)
                    and SOURCE_HASH.fullmatch(row["resource_sha256"]), "Invalid original level hash")
            if group == "models":
                require(integer(row.get("source_chunk"), 1, 0xffffffff)
                        and integer(row.get("source_id"), 0, 65535), "Invalid original actor selector")
                scale = row.get("scale", 1.0)
                require(type(scale) in (int, float) and 0.01 <= scale <= 10.0, "Invalid model scale")
                extent = row.get("reference_extent_m")
                require(isinstance(extent, list) and len(extent) == 3 and all(
                    type(axis) in (int, float) and 0.001 <= axis <= 100.0 for axis in extent
                ), "Expected three positive reference_extent_m axes (0.001–100 m)")
                scope = (row["source_chunk"], row["source_id"])
                suffix = ".glb"
            else:
                require(integer(row.get("blob"), 1, 127), "Expected one-based native sound blob 1–127")
                scope = (row["blob"],)
                suffix = ".wav"
            selector = (group, row["resource_sha256"], *scope)
            require(selector not in seen, f"Repeated selector: {selector}")
            seen.add(selector)
            path = asset(directory, row.get("file"), suffix)
            sources[group + "/" + row["file"]] = {"sha256": sha(path), "frames_or_meshes": verify(path)}
    return {"directory": str(directory), "name": data["name"], "assets": sources}


def patch(path, edits):
    text = path.read_text(encoding="utf-8-sig")
    for old, new in edits:
        require(text.count(old) == 1, f"Unsupported or already patched Time Busters frontend: {path}")
        text = text.replace(old, new, 1)
    return text


def plan(project):
    project = project.resolve(strict=True)
    require((project / "native/tb_reference.gdextension").is_file()
            and (project / "bundled/metadata/resource_manifest.json").is_file(),
            "Expected the bundled R12 C1 Godot project")
    require(not os.path.lexists(project / "reference/cosmetic_mods.gd"), "Expected an unmodified frontend copy")
    actual_pins = {name: sha(project / name) for name in SOURCE_PINS}
    for name, expected in SOURCE_PINS.items():
        require(actual_pins[name] == expected, f"Unsupported R12 C1 source fingerprint: {name}")
    files = {
        "reference/main.gd": patch(project / "reference/main.gd", MAIN_EDITS),
        "reference/native_audio.gd": patch(project / "reference/native_audio.gd", AUDIO_EDITS),
        "reference/cosmetic_mods.gd": (HERE / "cosmetic_mods.gd").read_text(encoding="utf-8-sig"),
        "project.godot": patch(project / "project.godot", (
            (PROFILE_ANCHOR, f'config/custom_user_dir_name="{MOD_PROFILE}"'),
        )),
    }
    return project, actual_pins, files


def install(project, destination):
    project, pins, files = plan(project)
    require(not os.path.lexists(destination), "Use a new destination outside the source project")
    destination = destination.resolve()
    require(not destination.is_relative_to(project) and not project.is_relative_to(destination),
            "Use a new destination outside the source project")
    profile_suffix = hashlib.sha256(os.path.normcase(str(destination)).encode()).hexdigest()[:16]
    user_dir_name = f"{MOD_PROFILE}-{profile_suffix}"
    files["project.godot"] = files["project.godot"].replace(MOD_PROFILE, user_dir_name, 1)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".tb-modkit-", dir=destination.parent) as stage:
        staged = Path(stage) / "project"
        shutil.copytree(project, staged, ignore=shutil.ignore_patterns(".godot"))
        require(all(sha(staged / name) == expected for name, expected in pins.items()),
                "Copied project differs from the checked source")
        for name, contents in files.items():
            (staged / name).write_bytes(contents.encode())
        patched = {name: sha(staged / name) for name in files}
        require(not os.path.lexists(destination), "Destination was created while preparing the copy")
        staged.rename(destination)
    return {"project": str(destination), "source": str(project),
            "native_module_sha256": pins["bin/tb_reference.dll"],
            "user_dir_name": user_dir_name, "patched_files": patched, "godot_executed": False}


def synthetic_glb(path):
    half_edge = 0.105
    edge = 2 * half_edge
    points = [(-half_edge, 0, -half_edge), (half_edge, 0, -half_edge),
              (half_edge, edge, -half_edge), (-half_edge, edge, -half_edge),
              (-half_edge, 0, half_edge), (half_edge, 0, half_edge),
              (half_edge, edge, half_edge), (-half_edge, edge, half_edge)]
    indices = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4,
               3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5]
    vertices = b"".join(struct.pack("<fff", *point) for point in points)
    blob = vertices + struct.pack("<" + "H" * len(indices), *indices)
    document = {
        "asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": "ExampleBox"}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1, "material": 0}]}],
        "materials": [{"pbrMetallicRoughness": {"baseColorFactor": [.04, .86, .78, 1],
                                               "metallicFactor": 0, "roughnessFactor": 1}}],
        "buffers": [{"byteLength": len(blob)}],
        "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": len(vertices), "target": 34962},
                        {"buffer": 0, "byteOffset": len(vertices), "byteLength": 2 * len(indices), "target": 34963}],
        "accessors": [{"bufferView": 0, "componentType": 5126, "count": len(points), "type": "VEC3",
                       "min": [-half_edge, 0, -half_edge], "max": [half_edge, edge, half_edge]},
                      {"bufferView": 1, "componentType": 5123, "count": len(indices), "type": "SCALAR"}],
    }
    metadata = json.dumps(document, separators=(",", ":")).encode()
    metadata += b" " * (-len(metadata) % 4)
    body = struct.pack("<I4s", len(metadata), b"JSON") + metadata + struct.pack("<I4s", len(blob), b"BIN\0") + blob
    path.write_bytes(struct.pack("<4sII", b"glTF", 2, len(body) + 12) + body)


def sample(directory, sound_blob):
    require(not os.path.lexists(directory), "Create the example in a new directory")
    directory = directory.resolve()
    if sound_blob is not None:
        require(integer(sound_blob, 1, 127), "Use a traced native one-shot blob from 1 to 127")
    directory.mkdir(parents=True)
    synthetic_glb(directory / "box.glb")
    if sound_blob is not None:
        with wave.open(str(directory / "click.wav"), "wb") as sound:
            sound.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            frames = (int(7000 * (1 - i / 2560) * math.sin(2 * math.pi * 560 * i / 16000)) for i in range(2560))
            sound.writeframes(struct.pack("<" + "h" * 2560, *frames))
    data = {"schema_version": 2, "name": "Example teal box and one-shot tone",
            "models": [{"resource_sha256": ARCA01_RU, "source_chunk": 84429, "source_id": 253,
                        "file": "box.glb", "reference_extent_m": [0.21, 0.21, 0.21]}],
            "sounds": [{"resource_sha256": ARCA01_RU, "blob": sound_blob,
                        "file": "click.wav"}] if sound_blob is not None else []}
    (directory / "mod.json").write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return validate(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    check = commands.add_parser("check")
    check.add_argument("--project", type=Path, required=True)
    apply = commands.add_parser("install")
    apply.add_argument("--project", type=Path, required=True)
    apply.add_argument("--destination", type=Path, required=True)
    verification = commands.add_parser("validate")
    verification.add_argument("directory", type=Path)
    example = commands.add_parser("example")
    example.add_argument("directory", type=Path)
    example.add_argument("--sound-blob", type=int)
    args = parser.parse_args()
    try:
        if args.action == "check":
            project, pins, files = plan(args.project)
            result = {"project": str(project), "source_pins": pins,
                      "planned_files": list(files), "godot_executed": False}
        elif args.action == "install":
            result = install(args.project, args.destination)
        elif args.action == "validate":
            result = validate(args.directory)
        else:
            result = sample(args.directory, args.sound_blob)
    except (ValueError, OSError, wave.Error, struct.error, EOFError) as error:
        parser.exit(2, f"modkit: {error}\n")
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()

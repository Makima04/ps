#!/usr/bin/env python3
"""Download pinned Core ML models, verify weight hashes, and compile for this Mac."""
import concurrent.futures
import hashlib
import pathlib
import subprocess
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / ".build" / "ModelSources"
OUTPUT = ROOT / "Sources" / "ColorEngine" / "Models"
MODELS = [
    ("FaceParsing", "mickeyvanolst/face-parsing-coreml", "289c64b0db3acb100e22a650becb5e300be8b7f4", {
        "Manifest.json": None,
        "Data/com.apple.CoreML/model.mlmodel": "2ca211f835ae6a42372304ca21257df7aab884bee6a548a7f9d28896887bd8e3",
    }),
    ("ClothSegmentation", "jerhoads/cloth-segmentation-coreml", "9c0a03afb544587402484a977d71383a1d79613d", {
        "Manifest.json": None,
        "Data/com.apple.CoreML/model.mlmodel": "81f20f3fc58948a9c34725041f13578fcb65412d2269ddf95bce9cd62852096a",
        "Data/com.apple.CoreML/weights/weight.bin": "f072202b77fbb5527d25829d4f79aba66ab2a8fb74de5d627ef6766a9ad0c9f4",
    }),
]


def download(name, repo, revision, relative, expected_hash):
    target = SOURCE / (name + ".mlpackage") / relative
    if target.exists() and (expected_hash is None or hashlib.sha256(target.read_bytes()).hexdigest() == expected_hash):
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    url = f"https://huggingface.co/{repo}/resolve/{revision}/{name}.mlpackage/{relative}"
    temporary = target.with_suffix(target.suffix + ".partial")
    try:
        with urllib.request.urlopen(url, timeout=120) as response, temporary.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
        if expected_hash and hashlib.sha256(temporary.read_bytes()).hexdigest() != expected_hash:
            raise RuntimeError(f"Checksum mismatch for {target.name}")
        temporary.replace(target)
        print(f"Downloaded {name}/{relative}", flush=True)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    pending = [model for model in MODELS if not (OUTPUT / (model[0] + ".mlmodelc")).is_dir()]
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        futures = [
            pool.submit(download, name, repo, revision, relative, checksum)
            for name, repo, revision, files in pending
            for relative, checksum in files.items()
        ]
        for future in futures:
            future.result()
    for name, _, _, _ in pending:
        subprocess.run(["xcrun", "coremlcompiler", "compile",
                        str(SOURCE / (name + ".mlpackage")), str(OUTPUT)], check=True)
        if not (OUTPUT / (name + ".mlmodelc")).is_dir():
            raise RuntimeError(f"Compilation did not produce {name}.mlmodelc")
        print(f"Prepared {name}", flush=True)


if __name__ == "__main__":
    main()

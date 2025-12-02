import json
import os
import pathlib
import re
import subprocess
import hashlib

with open(os.environ["NIX_ATTRS_JSON_FILE"], "r") as f:
    attrs = json.load(f)


class ExcludePattern:
    negate: bool
    pattern: re.Pattern

    def __init__(self, pat: str):
        if pat.startswith("!"):
            self.verdict = False
            pat = pat[1:]
        else:
            self.verdict = True

        if not pat.endswith("/"):
            pat = pat + "$"

        self.pattern = re.compile("^" + pat)

    def test(self, path: pathlib.Path) -> bool | None:
        return self.verdict if self.pattern.match(str(path)) else None


exclude_patterns = list(map(ExcludePattern, attrs["excludePatterns"]))


def should_exclude(path: pathlib.Path):
    exclude = False

    for pat in exclude_patterns:
        verdict = pat.test(path)
        if verdict is not None:
            exclude = verdict

    return exclude


files_to_compress = []


def collect_files(path: pathlib.Path):
    if path.is_file():
        if not should_exclude(path):
            files_to_compress.append(path)
    elif path.is_symlink():
        target = path.readlink()
        if not (should_exclude(path) or should_exclude(target)):
            files_to_compress.append(path)
    elif path.is_dir():
        for ent in path.iterdir():
            collect_files(ent)


for closure_ent in attrs["closure"]:
    collect_files(pathlib.Path(closure_ent["path"]))

compressed_closure = os.environ["out"]
print(f"Compressing {len(files_to_compress)} files to {compressed_closure}")

subprocess.run(
    [
        "mksquashfs",
        "-",
        compressed_closure,
        "-no-strip",
        "-cpiostyle",
        "-comp",
        "xz",
    ],
    input="".join(f"{f}\n" for f in files_to_compress).encode(),
    stdout=subprocess.DEVNULL,
    check=True,
)

closure_size = os.stat(compressed_closure).st_size
print(f" - done; compressed closure size {closure_size / 1024 / 1024:.3f}MB")

with open(compressed_closure, "rb") as f:
    digest = hashlib.sha256(f.read()).hexdigest()
    pathlib.Path(os.environ["hash"]).write_text(digest)

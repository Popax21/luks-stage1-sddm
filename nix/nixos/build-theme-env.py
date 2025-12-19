from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

with open(os.environ["NIX_ATTRS_JSON_FILE"], "r") as q:
    attrs = json.load(q)

out = Path(os.environ["out"])
raw_env = Path(attrs["rawEnv"])
qml_modules = attrs["qmlModules"]
fixups = attrs["fixups"]


def map_to_out_path(path: Path) -> Path:
    assert path.is_absolute(), path

    if path.is_relative_to(out) or len(path.parts) == len(out.parts):
        return path

    out_path = out / path.relative_to(path.parents[-(len(raw_env.parents) + 1)])
    out_path.parent.mkdir(parents=True, exist_ok=True)
    return out_path


def apply_fixups(path: Path):
    path = map_to_out_path(path)
    assert path.is_file(), path

    if len(path.parts) == len(out.parts):
        return

    fxs = []

    def collect_fixups(path_module: str):
        if path_module in fixups:
            fxs.extend(fixups[path_module].splitlines(keepends=False))

    # collect fixups which reference either:
    #  - the file itself
    collect_fixups(str(path.relative_to(out)))

    #  - any parent directories of the file
    for p in path.relative_to(out).parents:
        collect_fixups(f"{p}/")

    # if we found any fixups, apply them now
    if fxs:
        print(f"Applying fixups to {path.relative_to(out)}")
        for fx in fxs:
            print(f" - {fx}")
            env = os.environ.copy()
            env["target"] = str(path)
            subprocess.check_call(fx, shell=True, env=env)


def include_path(path: Path) -> Path:
    out_path = map_to_out_path(path)
    if path.is_symlink():
        p = include_path((path.parent / path.readlink()).resolve())
        if not out_path.exists():
            out_path.symlink_to(p)
    elif path.is_dir():
        for f in path.iterdir():
            include_path(f)
    elif path.is_file(follow_symlinks=False):
        if not out_path.exists():
            shutil.copyfile(path, out_path)
            apply_fixups(path)
    else:
        assert False

    return out_path


QML_COMMENT_REGEX = re.compile("//.*$")
QML_MULTICOMMENT_REGEX = re.compile("/\\*.*?\\*/", re.DOTALL)
QML_TYPE_REGEX = re.compile("[A-Z][a-zA-Z0-9_]+")
QMLTYPES_EXPORT_REGEX = re.compile('"([a-zA-Z0-9.]+)/([A-Z][a-zA-Z0-9_]+) [^ ]+"')

MISSING_QT_PLUGINS: list[tuple[QmlModule, str]] = []


class QmlModule:
    MODULES: dict[str, QmlModule | None] = dict()
    COPIED_MODULES: list[str] = list()

    @staticmethod
    def import_module(
        name: str, for_module: QmlModule | None = None
    ) -> QmlModule | None:
        if name in QmlModule.MODULES:
            return QmlModule.MODULES[name]

        # ignore base Qt modules
        if name.startswith("Qt"):
            return None

        subdir = Path("lib", "qt-6", "qml", *name.split("."))

        # apply user module substitutions
        if name in qml_modules:
            assert not (out / subdir).exists()

            env = Path(qml_modules[name])
            path = env / subdir
            plugin_ok = True

            if not (path.is_dir() and (path / "qmldir").is_file()):
                print()
                print(
                    f"Substitute package {qml_modules[name]} for QML module {name} does not contain said module"
                )
                exit(1)

            print(f"Substituting QML module {name} from package {qml_modules[name]}")
        else:
            env = raw_env if for_module is None else for_module.env
            path = env / subdir
            plugin_ok = for_module is not None and for_module.plugin_ok

        # check if the QML module dir exists and has a 'qmldir' file
        if path.is_dir() and (path / "qmldir").is_file():
            m = QmlModule(name, path, env, plugin_ok)
            QmlModule.MODULES[name] = m
            QmlModule.COPIED_MODULES.append(name)
            return m
        else:
            return None

    name: str
    path: Path
    env: Path
    include_plugin: bool
    plugin_ok: bool

    _incl_types: dict[str, list[str]]
    _qml_types: dict[str, Path]
    _plugin_types: set[str]
    _imported_mods: list[QmlModule]

    def __init__(self, name: str, path: Path, env: Path, plugin_ok: bool):
        self.name = name
        self.path = path
        self.env = env
        self.include_plugin = False
        self.plugin_ok = plugin_ok

        self._incl_types = dict()
        self._qml_types = dict()
        self._plugin_types = set()
        self._imported_mods = list()

        # parse the module's qmldir file
        has_plugin, has_plugin_typeinfo = False, False

        with include_path(path / "qmldir").open("r") as f:
            for l in f:
                a = l.strip().split()
                if not a:
                    continue

                if len(a) == 3 and a[2].endswith(".qml"):
                    # - QML module declaration
                    ty = a[0] if a[0] != "internal" else a[1]
                    self._qml_types[ty] = path / a[2]
                elif a[0] == "plugin" or (a[0] == "optional" and a[1] == "plugin"):
                    # - plugin declaration
                    has_plugin = True
                elif a[0] == "typeinfo":
                    # - plugin .qmltypes file
                    has_plugin_typeinfo = True
                    self._parse_typeinfo(path / a[1])
                elif a[0] == "import":
                    # - top-level module import
                    m = QmlModule.import_module(a[1], for_module=self)
                    if m:
                        self._imported_mods.append(m)

        # check for a `force-plugin` file
        if (path / "force-plugin").is_file():
            assert has_plugin
            self.include_plugin = True

        # warn if we have a plugin but no .qmltypes file (which we need to discover exported plugin types)
        if has_plugin and not (has_plugin_typeinfo or self.include_plugin):
            print(
                f"WARN: QML module {name} has a native Qt plugin but no typeinfo file; unable to assess plugin usage"
            )

            self.include_plugin = True

    @property
    def is_used(self) -> bool:
        return self.include_plugin or len(self._incl_types) > 0

    def __repr__(self) -> str:
        return f"QmlModule({self.name})"

    def _parse_typeinfo(self, path: Path):
        # discover exported plugin types
        for exp in QMLTYPES_EXPORT_REGEX.finditer(path.read_text()):
            if exp.group(1) == self.name:
                self._plugin_types.add(exp.group(2))

    def include_type(self, ty: str, includers: list[str]):
        if ty in self._incl_types:
            return

        if ty in self._qml_types:
            # QML-provided type; include the QML type in the output env
            self._incl_types[ty] = includers

            process_qml_file(
                include_path(self._qml_types[ty]),
                module=self,
                includers=includers,
            )
        elif ty in self._plugin_types:
            # plugin-provided type; include the plugin in the output env
            self._incl_types[ty] = includers
            self.include_plugin = True
        else:
            # not provided by the module itself, tho it might be provided by an imported module
            for m in self._imported_mods:
                m.include_type(ty, includers)

    def fixup(self):
        qmldir = map_to_out_path(self.path / "qmldir")
        assert qmldir.is_file()

        # unused QML modules (i.e. modules with no used types) are removed completely
        if not self.is_used:
            qmldir.unlink()
            return

        # filter qmldir statements to only include relevant / "kept" ones
        with qmldir.open("r+") as f:
            lines = f.readlines()
            f.truncate(0)
            f.seek(0)

            for l in map(self._filter_qmldir_line, lines):
                if l:
                    f.write(l.strip() + "\n")

    def _filter_qmldir_line(self, line: str) -> str | None:
        a = line.strip().split()
        if not a:
            return None

        if len(a) == 3 and a[2].endswith(".qml"):
            ty = a[0] if a[0] != "internal" else a[1]

            # only QML files containing used types are actually included in the output
            if not ty in self._incl_types:
                return None

            # fixups may insert type declarations with absolute paths - clean this up
            ap = Path(a[2])
            if ap.is_absolute() and ap.is_file():
                a[2] = f"{ty}.qml"
                line = " ".join(a)

                shutil.copy(ap, map_to_out_path(self.path / a[2]))

            assert map_to_out_path(self.path / a[2]).is_file()
            return line
        elif a[0] == "plugin":
            return self._filter_qmldir_plugin(a[1])
        elif a[0] == "optional" and a[1] == "plugin":
            return self._filter_qmldir_plugin(a[2])
        elif a[0] == "typeinfo":
            # we don't need the typeinfo file in the actual output env
            return None
        elif a[0] == "depends" or a[0] == "import":
            # only include dependencies / imports which are actually used
            m = QmlModule.import_module(a[1])
            if not m or m.is_used:
                return line
            else:
                return None
        elif a[0] == "prefer":
            # we don't ship any QML caches / etc
            return None
        else:
            return line

    def _filter_qmldir_plugin(self, plugin: str) -> str | None:
        if not self.include_plugin:
            return None

        plugin_so = f"lib{plugin}.so"

        if self.plugin_ok:
            print(f"Including native Qt plugin {plugin_so} for QML module {self.name}")
            include_path(self.path / plugin_so)
            return f"plugin {plugin}"

        # the plugin is needed, but it's not suitable for initrd conditions
        global MISSING_QT_PLUGINS
        MISSING_QT_PLUGINS.append((self, plugin_so))

        return None

    def print_missing_plugin_error(self, plugin: str):
        print(
            f"ERROR: missing native Qt plugin {plugin} for QML module {self.name}, required by:"
        )

        for ty in self._plugin_types:
            if not ty in self._incl_types:
                continue

            print(f" - QML type {ty}")
            for incl in self._incl_types[ty]:
                print(f"   - used by {incl}")


PROCESSED_QML_FILES: set[Path] = set()


def process_qml_file(
    qml: Path, module: QmlModule | None = None, includers: list[str] = []
):
    if qml in PROCESSED_QML_FILES:
        return
    PROCESSED_QML_FILES.add(qml)

    if module is None:
        includers = [str(qml.relative_to(out))] + includers
    else:
        includers = [f"module {module.name} file {qml.name}"] + includers

    # discover used QML types / modules
    code = qml.read_text()
    code = QML_COMMENT_REGEX.sub("", code)
    code = QML_MULTICOMMENT_REGEX.sub("", code)

    # - find import statements
    mods: list[QmlModule] = []

    if module is not None:
        mods.append(module)

    for l in code.splitlines():
        a = l.strip().split()
        if not a or a[0] != "import":
            continue

        m = QmlModule.import_module(a[1], for_module=module)
        if m is not None:
            mods.append(m)

    # - find used types from said imports
    for ty in map(lambda m: m.group(), QML_TYPE_REGEX.finditer(code)):
        for m in mods:
            m.include_type(ty, includers)


def include_theme_conf(conf: Path):
    with conf.open("r") as f, map_to_out_path(conf).open("w") as of:
        for l in f:
            # copy over files referenced by config keys
            if "=" in l:
                k, v = l.strip().split("=", 2)
                if Path(v).exists():
                    of.write(f"{k}={include_path(Path(v))}\n")
                    continue

            of.write(l)

    apply_fixups(conf)


# copy over all SDDM theme files
for f in raw_env.glob("share/sddm/themes/**/*", recurse_symlinks=True):
    if f.name.endswith(".qml"):
        process_qml_file(include_path(f))
    elif f.name.startswith("theme.conf"):
        include_theme_conf(f)
    else:
        include_path(f)

# copy over locale / icon data
if (raw_env / "share" / "locale").exists():
    include_path(raw_env / "share" / "locale")

if (raw_env / "share" / "icons").exists():
    include_path(raw_env / "share" / "icons")

# fixup QML modules
i = 0
while i < len(QmlModule.COPIED_MODULES):
    m = QmlModule.MODULES[QmlModule.COPIED_MODULES[i]]
    assert m is not None
    m.fixup()
    i += 1

# if we are missing any native Qt plugins then error out
if MISSING_QT_PLUGINS:
    print()
    for m, p in MISSING_QT_PLUGINS:
        m.print_missing_plugin_error(p)
        print()
    print(f"missing {len(MISSING_QT_PLUGINS)} required native Qt plugins; erroring out")
    exit(1)


# remove empty dirs
def rm_empty_dirs(path: Path) -> bool:
    is_empty = True
    for ent in path.iterdir():
        if ent.is_dir(follow_symlinks=False) and rm_empty_dirs(ent):
            continue
        is_empty = False

    if is_empty:
        path.rmdir()

    return is_empty


assert not rm_empty_dirs(out)

print()
print(
    "Built theme environment in %s containing %d QML modules (%d native plugins)"
    % (
        out,
        sum(1 for m in QmlModule.MODULES.values() if m and m.is_used),
        sum(1 for m in QmlModule.MODULES.values() if m and m.include_plugin),
    )
)

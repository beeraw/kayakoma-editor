#!/usr/bin/env python3
"""Keeps Localizable.xcstrings in sync with one XLIFF file per language.

The XLIFF files in Translations/ are the reference for every language other
than the source language (French, whose text lives in the code). They use
XLIFF 1.2 as written by Xcode's "Export Localizations", so a file exported by
Xcode or returned by a translation tool can be dropped in as is.

    translations.py import   [--catalog FILE] [--translations DIR]
    translations.py export   [--catalog FILE] [--translations DIR] [--new LANG]
    translations.py selftest [--catalog FILE]

import  writes the translations of every Translations/*.xliff into the
        catalog (the language is read from the file's target-language).
        Empty targets are skipped: the app falls back to French. The catalog
        is only rewritten when something changed, keeping its key order and
        JSON layout.
export  refreshes every Translations/*.xliff from the catalog: new strings
        are added with an empty target, strings gone from the catalog are
        dropped, existing translations and translator notes are kept.
        --new LANG creates Translations/LANG.xliff first.

Both commands also keep Translations/Translations.xcfilelist up to date: the
list of XLIFF files that the sandboxed build phase is allowed to read.

Without --catalog, the catalog is the only <folder>/Localizable.xcstrings of
the repository holding this script; without --translations, the folder is
Translations/ at the root of that repository.

Plain Python 3.9 with no dependencies, so that it runs from an Xcode build
phase with the interpreter shipped with the developer tools.
"""

import argparse
import copy
import glob
import json
import os
import re
import shutil
import sys
import tempfile
import xml.etree.ElementTree as ET

XLIFF_NS = "urn:oasis:names:tc:xliff:document:1.2"
NS = {"x": XLIFF_NS}
XML_SPACE = "{http://www.w3.org/XML/1998/namespace}space"
ID_SEPARATOR = "|==|"

# CLDR plural categories, in CLDR order, for languages that differ from
# "one" + "other". Used to offer the right plural forms to translators.
PLURAL_ORDER = ["zero", "one", "two", "few", "many", "other"]
PLURAL_CATEGORIES = {
    "ja": ["other"], "ko": ["other"], "zh": ["other"], "id": ["other"],
    "ms": ["other"], "th": ["other"], "vi": ["other"],
    "ru": ["one", "few", "many", "other"], "uk": ["one", "few", "many", "other"],
    "pl": ["one", "few", "many", "other"], "cs": ["one", "few", "many", "other"],
    "sk": ["one", "few", "many", "other"], "hr": ["one", "few", "other"],
    "sr": ["one", "few", "other"], "he": ["one", "two", "other"],
    "ar": ["zero", "one", "two", "few", "many", "other"],
}

# XLIFF target states and string catalog states.
REVIEW_STATES = {"needs-review-translation", "needs-review-l10n", "needs-review-adaptation"}
CATALOG_TO_XLIFF_STATE = {"translated": "translated", "needs_review": "needs-review-translation"}


QUIET = False


def log(message):
    if not QUIET:
        print("translations: " + message, file=sys.stderr)


# --------------------------------------------------------------------------
# String catalog

class Catalog:
    """A Localizable.xcstrings file, rewritten in the layout it was read in."""

    def __init__(self, path):
        self.path = path
        with open(path, encoding="utf-8") as handle:
            self.raw = handle.read()
        self.data = json.loads(self.raw)
        self.original = copy.deepcopy(self.data)
        self.separator = " : " if '" : ' in self.raw else ": "
        self.trailing_newline = self.raw.endswith("\n")

    @property
    def source_language(self):
        return self.data.get("sourceLanguage", "en")

    @property
    def strings(self):
        return self.data.setdefault("strings", {})

    def render(self):
        text = json.dumps(self.data, indent=2, ensure_ascii=False,
                          separators=(",", self.separator))
        return text + ("\n" if self.trailing_newline else "")

    def save_if_changed(self):
        if self.data == self.original:
            return False
        with open(self.path, "w", encoding="utf-8") as handle:
            handle.write(self.render())
        return True


def put(mapping, key, value):
    """Sets a key, inserting a new one where Xcode would put it.

    Xcode writes keys in sorted order: a new key goes to its sorted place when
    the existing keys are sorted, and at the end otherwise.
    """
    if key in mapping or list(mapping) != sorted(mapping):
        mapping[key] = value
        return
    items = list(mapping.items()) + [(key, value)]
    mapping.clear()
    for item_key, item_value in sorted(items, key=lambda item: item[0]):
        mapping[item_key] = item_value


def plural_categories(language):
    base = language.split("-")[0].split("_")[0]
    return PLURAL_CATEGORIES.get(language, PLURAL_CATEGORIES.get(base, ["one", "other"]))


def ordered_cases(cases):
    return sorted(cases, key=lambda case: (PLURAL_ORDER.index(case) if case in PLURAL_ORDER else 99, case))


def arg_token(substitution):
    return "%{}${}".format(substitution.get("argNum", 1), substitution.get("formatSpecifier", "@"))


def source_localization(catalog, key):
    """The source-language entry of a key; the key itself when there is none."""
    entry = catalog.strings[key]
    localization = entry.get("localizations", {}).get(catalog.source_language)
    if localization is None:
        return {"stringUnit": {"state": "translated", "value": key}}
    return localization


def flatten_variations(variations, prefix=""):
    """Yields (path, stringUnit-holder) for every leaf of nested variations."""
    for kind in variations:
        for case in ordered_cases(variations[kind]):
            node = variations[kind][case]
            path = "{}{}.{}".format(prefix, kind, case)
            if "variations" in node:
                for item in flatten_variations(node["variations"], path + "."):
                    yield item
            else:
                yield path, node


def catalog_units(catalog, language):
    """The XLIFF units of the catalog for a language, in a stable order.

    Each unit is a dict with id, source, target, state and comment; target is
    None when the catalog has no translation for that unit.
    """
    units = []
    for key in sorted(catalog.strings):
        entry = catalog.strings[key]
        if entry.get("shouldTranslate") is False:
            continue
        comment = entry.get("comment", "")
        source = source_localization(catalog, key)
        target = entry.get("localizations", {}).get(language, {})

        def unit(unit_id, source_unit, target_unit, transform=None):
            source_value = source_unit.get("stringUnit", {}).get("value", "")
            target_string = (target_unit or {}).get("stringUnit", {})
            target_value = target_string.get("value")
            if transform:
                source_value = transform(source_value)
                target_value = transform(target_value) if target_value is not None else None
            units.append({
                "id": unit_id, "source": source_value,
                "target": target_value or None,
                "state": target_string.get("state"), "comment": comment,
            })

        if "stringUnit" in source:
            substitutions = source.get("substitutions", {})
            unit(key, source, target,
                 transform=(lambda value: number_substitutions(value, substitutions)) if substitutions else None)
        if "variations" in source:
            source_leaves = dict(flatten_variations(source["variations"]))
            target_leaves = dict(flatten_variations(target.get("variations", {})))
            for path in variation_paths(source_leaves, target_leaves, language):
                fallback = source_leaves.get(path) or source_leaves.get(other_path(path), {})
                unit(key + ID_SEPARATOR + path, fallback, target_leaves.get(path))
        for name in sorted(source.get("substitutions", {})):
            source_sub = source["substitutions"][name]
            target_sub = target.get("substitutions", {}).get(name, {})
            token = arg_token(source_sub)
            source_leaves = dict(flatten_variations(source_sub.get("variations", {})))
            target_leaves = dict(flatten_variations(target_sub.get("variations", {})))
            for path in variation_paths(source_leaves, target_leaves, language):
                fallback = source_leaves.get(path) or source_leaves.get(other_path(path), {})
                unit("{}{}substitutions.{}.{}".format(key, ID_SEPARATOR, name, path),
                     fallback, target_leaves.get(path),
                     transform=lambda value, token=token: value.replace("%arg", token))
    return units


def number_substitutions(value, substitutions):
    """%#@name@ becomes %2$#@name@, the argument number Xcode writes in XLIFF."""
    for name, substitution in substitutions.items():
        value = value.replace("%#@{}@".format(name), "%{}$#@{}@".format(substitution.get("argNum", 1), name))
    return value


def unnumber_substitutions(value, source_value, substitutions):
    """Reverts number_substitutions for the tokens the source writes unnumbered."""
    for name, substitution in substitutions.items():
        if "%#@{}@".format(name) in source_value:
            value = value.replace("%{}$#@{}@".format(substitution.get("argNum", 1), name), "%#@{}@".format(name))
    return value


def other_path(path):
    return path.rsplit(".", 1)[0] + ".other"


def variation_paths(source_leaves, target_leaves, language):
    """Source cases, plus the target's own, with the plural forms of the language.

    Like Xcode, a plural offers the forms of the target language only (just
    "other" in Japanese, four forms in Russian), plus any the target has.
    """
    def is_plural(path):
        return path.rsplit(".", 2)[-2:-1] == ["plural"]

    categories = plural_categories(language)
    paths = [path for path in source_leaves
             if not is_plural(path) or path.rsplit(".", 1)[1] in categories]
    for path in target_leaves:
        if path not in paths:
            paths.append(path)
    plural_prefixes = {path.rsplit(".", 1)[0] for path in list(source_leaves) + paths if is_plural(path)}
    for prefix in plural_prefixes:
        for case in plural_categories(language):
            path = prefix + "." + case
            if path not in paths:
                paths.append(path)

    def order(path):
        prefix, case = path.rsplit(".", 1)
        return (prefix, PLURAL_ORDER.index(case) if case in PLURAL_ORDER else 99, case)
    return sorted(paths, key=order)


# --------------------------------------------------------------------------
# XLIFF

class XliffFile:
    """The units of the string catalog in one XLIFF file."""

    def __init__(self, path):
        self.path = path
        self.language = None
        self.units = {}
        tree = ET.parse(path)
        for file_element in tree.getroot().findall("x:file", NS):
            if not file_element.get("original", "").endswith("Localizable.xcstrings"):
                continue
            self.language = file_element.get("target-language") or self.language
            for unit in file_element.iter("{%s}trans-unit" % XLIFF_NS):
                source = unit.find("x:source", NS)
                target = unit.find("x:target", NS)
                notes = unit.findall("x:note", NS)
                self.units[unit.get("id")] = {
                    "source": "".join(source.itertext()) if source is not None else "",
                    "target": "".join(target.itertext()) if target is not None else "",
                    "state": target.get("state") if target is not None else None,
                    "notes": [(note.get("from"), "".join(note.itertext())) for note in notes],
                }
        if self.language is None:
            root_file = tree.getroot().find("x:file", NS)
            if root_file is not None:
                self.language = root_file.get("target-language")


def escape(text, attribute=False):
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    if attribute:
        text = text.replace('"', "&quot;")
    return text


def write_xliff(path, original, source_language, language, units):
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<xliff xmlns="{}" version="1.2">'.format(XLIFF_NS),
        '  <file original="{}" source-language="{}" target-language="{}" datatype="plaintext">'.format(
            escape(original, True), escape(source_language, True), escape(language, True)),
        "    <body>",
    ]
    for unit in units:
        lines.append('      <trans-unit id="{}" xml:space="preserve">'.format(escape(unit["id"], True)))
        lines.append("        <source>{}</source>".format(escape(unit["source"])))
        lines.append('        <target state="{}">{}</target>'.format(unit["state"], escape(unit["target"] or "")))
        for origin, text in unit["notes"]:
            attribute = ' from="{}"'.format(escape(origin, True)) if origin else ""
            lines.append("        <note{}>{}</note>".format(attribute, escape(text)) if text
                         else "        <note{}/>".format(attribute))
        lines.append("      </trans-unit>")
    lines += ["    </body>", "  </file>", "</xliff>", ""]
    content = "\n".join(lines)
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            if handle.read() == content:
                return False
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(content)
    return True


# --------------------------------------------------------------------------
# Import

def import_translations(catalog, xliff):
    """Writes the non-empty targets of an XLIFF file into the catalog."""
    language = xliff.language
    unknown = 0
    for unit_id, unit in xliff.units.items():
        value = unit["target"]
        if not value:
            continue
        key, _, path = unit_id.partition(ID_SEPARATOR)
        if key not in catalog.strings:
            unknown += 1
            continue
        state = "needs_review" if unit["state"] in REVIEW_STATES else "translated"
        source = source_localization(catalog, key)
        entry = catalog.strings[key]
        localizations = entry.setdefault("localizations", {})
        if language not in localizations:
            put(localizations, language, {})
        localization = localizations[language]
        if not path:
            source_value = source.get("stringUnit", {}).get("value", "")
            value = unnumber_substitutions(value, source_value, source.get("substitutions", {}))
            set_string_unit(localization, value, state)
        elif path.startswith("substitutions."):
            _, name, rest = path.split(".", 2)
            source_sub = source.get("substitutions", {}).get(name)
            if source_sub is None:
                unknown += 1
                continue
            substitutions = localization.get("substitutions")
            if substitutions is None:
                put(localization, "substitutions", {})
                substitutions = localization["substitutions"]
            if name not in substitutions:
                fresh = {}
                for field in ("argNum", "formatSpecifier"):
                    if field in source_sub:
                        fresh[field] = source_sub[field]
                put(substitutions, name, fresh)
            target_sub = substitutions[name]
            for field in ("argNum", "formatSpecifier"):
                if field in source_sub and target_sub.get(field) != source_sub[field]:
                    put(target_sub, field, source_sub[field])
            value = value.replace(arg_token(source_sub), "%arg")
            set_variation(target_sub, rest, value, state)
        else:
            set_variation(localization, path, value, state)
    if unknown:
        log("{}: {} unit(s) not in the catalog, skipped".format(os.path.basename(xliff.path), unknown))


def set_string_unit(holder, value, state):
    current = holder.get("stringUnit")
    if current is None:
        put(holder, "stringUnit", {"state": state, "value": value})
        return
    if current.get("value") != value:
        put(current, "value", value)
    if current.get("state") != state:
        put(current, "state", state)


def set_variation(holder, path, value, state):
    parts = path.split(".")
    node = holder
    for index in range(0, len(parts), 2):
        kind, case = parts[index], parts[index + 1]
        if "variations" not in node:
            put(node, "variations", {})
        if kind not in node["variations"]:
            put(node["variations"], kind, {})
        if case not in node["variations"][kind]:
            put(node["variations"][kind], case, {})
        node = node["variations"][kind][case]
    set_string_unit(node, value, state)


def xliff_files(directory):
    return sorted(glob.glob(os.path.join(directory, "*.xliff")))


def catalog_languages(catalog):
    languages = set()
    for entry in catalog.strings.values():
        languages.update(entry.get("localizations", {}))
    return languages


FILE_LIST = "Translations.xcfilelist"


def refresh_file_list(directory):
    """Lists the XLIFF files for the build phase, which reads declared files only.

    Xcode's script sandbox lets the build phase open the files named in this
    list and nothing else of the folder. The list is rewritten by every import
    or export run outside the sandbox: by hand, or by the scheme's pre-action,
    which runs before Xcode plans the build.
    """
    path = os.path.join(directory, FILE_LIST)
    names = [os.path.basename(item) for item in xliff_files(directory)]
    content = "".join("$(SRCROOT)/{}/{}\n".format(os.path.basename(directory), name) for name in names)
    try:
        with open(path, encoding="utf-8") as handle:
            if handle.read() == content:
                return
    except OSError:
        pass
    try:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)
    except OSError:
        # Inside the build phase's sandbox: the list cannot change there.
        pass


def run_import(catalog_path, directory, refresh_list=True):
    if refresh_list:
        refresh_file_list(directory)
    catalog = Catalog(catalog_path)
    languages_before = catalog_languages(catalog)
    imported = set()
    for path in xliff_files(directory):
        try:
            xliff = XliffFile(path)
        except PermissionError:
            print("warning: {} is not in {} yet; build with the app's scheme or run "
                  "scripts/translations.py import to include it".format(os.path.basename(path), FILE_LIST))
            continue
        if not xliff.language:
            log("{}: no target-language, skipped".format(os.path.basename(path)))
            continue
        if xliff.language == catalog.source_language:
            log("{}: source language, skipped".format(os.path.basename(path)))
            continue
        stem = os.path.splitext(os.path.basename(path))[0]
        if stem != xliff.language:
            log("{}: target-language is {}".format(os.path.basename(path), xliff.language))
        import_translations(catalog, xliff)
        imported.add(xliff.language)
    languages = catalog_languages(catalog)
    for language in sorted(languages - imported - {catalog.source_language}):
        log("warning: {} is in the catalog but has no XLIFF file in {}".format(
            language, os.path.basename(directory)))
    changed = catalog.save_if_changed()
    if changed:
        log("updated " + os.path.basename(catalog_path))
    # Xcode settles the languages of the app before the build phases run: a
    # language added by the build phase only ships from the next build. The
    # scheme's pre-action runs this import earlier and avoids it.
    added = sorted(languages - languages_before)
    if added and os.environ.get("SCRIPT_OUTPUT_FILE_0"):
        print("warning: added {} to the string catalog; build again to include it in the app"
              .format(", ".join(added)))
    return changed


# --------------------------------------------------------------------------
# Export

def run_export(catalog_path, directory, new_language=None):
    catalog = Catalog(catalog_path)
    original = os.path.relpath(catalog_path, os.path.dirname(os.path.abspath(directory)))
    paths = xliff_files(directory)
    if new_language:
        path = os.path.join(directory, new_language + ".xliff")
        if os.path.exists(path):
            raise SystemExit("translations: {} already exists".format(path))
        os.makedirs(directory, exist_ok=True)
        paths.append(path)
    changed = []
    for path in paths:
        existing = XliffFile(path) if os.path.exists(path) else None
        language = existing.language if existing and existing.language else new_language
        if not language:
            log("{}: no target-language, skipped".format(os.path.basename(path)))
            continue
        units = []
        for unit in catalog_units(catalog, language):
            previous = existing.units.get(unit["id"]) if existing else None
            if previous and previous["target"]:
                target, state = previous["target"], previous["state"] or "translated"
            elif unit["target"]:
                target = unit["target"]
                state = CATALOG_TO_XLIFF_STATE.get(unit["state"], "translated")
            else:
                target, state = None, "new"
            notes = [(None, unit["comment"])]
            if previous:
                notes += [note for note in previous["notes"] if note[0] not in (None, "developer")]
            units.append({"id": unit["id"], "source": unit["source"], "target": target,
                          "state": state, "notes": notes})
        if write_xliff(path, original, catalog.source_language, language, units):
            changed.append(os.path.basename(path))
    refresh_file_list(directory)
    log("exported: " + (", ".join(changed) if changed else "nothing changed"))


# --------------------------------------------------------------------------
# Self-test

FIXTURE = {
    "sourceLanguage": "fr",
    "strings": {
        "%lld mots": {"localizations": {
            "en": {"variations": {"plural": {
                "one": {"stringUnit": {"state": "translated", "value": "%lld word"}},
                "other": {"stringUnit": {"state": "translated", "value": "%lld words"}}}}},
            "fr": {"variations": {"plural": {
                "one": {"stringUnit": {"state": "translated", "value": "%lld mot"}},
                "other": {"stringUnit": {"state": "translated", "value": "%lld mots"}}}}}}},
        "« %@ » contient %lld fichiers": {"localizations": {
            "en": {"stringUnit": {"state": "translated", "value": "“%1$@” holds %#@files@"},
                   "substitutions": {"files": {"argNum": 2, "formatSpecifier": "lld", "variations": {"plural": {
                       "one": {"stringUnit": {"state": "translated", "value": "%arg file"}},
                       "other": {"stringUnit": {"state": "translated", "value": "%arg files"}}}}}}},
            "fr": {"stringUnit": {"state": "translated", "value": "« %1$@ » contient %#@files@"},
                   "substitutions": {"files": {"argNum": 2, "formatSpecifier": "lld", "variations": {"plural": {
                       "one": {"stringUnit": {"state": "translated", "value": "%arg fichier"}},
                       "other": {"stringUnit": {"state": "translated", "value": "%arg fichiers"}}}}}}}}},
        "Enregistrer": {"comment": "Save button.", "extractionState": "manual", "localizations": {
            "en": {"stringUnit": {"state": "translated", "value": "Save"}},
            "fr": {"stringUnit": {"state": "translated", "value": "Enregistrer"}}}},
        "Nouveau": {"localizations": {
            "fr": {"stringUnit": {"state": "translated", "value": "Nouveau"}}}},
        "Ouvrir <fichier> & \"lien\"": {"localizations": {
            "en": {"stringUnit": {"state": "needs_review", "value": "Open <file> & \"link\""}},
            "fr": {"stringUnit": {"state": "translated", "value": "Ouvrir <fichier> & \"lien\""}}}},
    },
    "version": "1.0",
}

ES_XLIFF = """<?xml version="1.0" encoding="UTF-8"?>
<xliff xmlns="urn:oasis:names:tc:xliff:document:1.2" version="1.2">
  <file original="App/InfoPlist.xcstrings" source-language="fr" target-language="es" datatype="plaintext">
    <body>
      <trans-unit id="CFBundleName" xml:space="preserve"><source>App</source><target>App</target></trans-unit>
    </body>
  </file>
  <file original="App/Localizable.xcstrings" source-language="fr" target-language="es" datatype="plaintext">
    <body>
      <trans-unit id="Enregistrer" xml:space="preserve">
        <source>Enregistrer</source>
        <target state="translated">Guardar</target>
      </trans-unit>
      <trans-unit id="%lld mots|==|plural.one" xml:space="preserve">
        <source>%lld mot</source>
        <target state="needs-review-translation">%lld palabra</target>
      </trans-unit>
      <trans-unit id="%lld mots|==|plural.other" xml:space="preserve">
        <source>%lld mots</source>
        <target state="needs-review-translation">%lld palabras</target>
      </trans-unit>
      <trans-unit id="Nouveau" xml:space="preserve">
        <source>Nouveau</source>
        <target state="new"></target>
      </trans-unit>
    </body>
  </file>
</xliff>
"""


def selftest(real_catalog=None, real_translations=None):
    global QUIET
    QUIET = True
    failures = []

    def check(condition, message):
        print(("ok    " if condition else "FAIL  ") + message)
        if not condition:
            failures.append(message)

    def read(path):
        with open(path, encoding="utf-8") as handle:
            return handle.read()

    work = tempfile.mkdtemp(prefix="translations-selftest-")
    try:
        for separator, newline in ((" : ", False), (": ", True)):
            label = "layout {!r}{}".format(separator, " + newline" if newline else "")
            root = os.path.join(work, "xcode" if newline is False else "plain")
            os.makedirs(os.path.join(root, "App"))
            catalog_path = os.path.join(root, "App", "Localizable.xcstrings")
            directory = os.path.join(root, "Translations")
            original_text = json.dumps(FIXTURE, indent=2, ensure_ascii=False,
                                       separators=(",", separator)) + ("\n" if newline else "")
            with open(catalog_path, "w", encoding="utf-8") as handle:
                handle.write(original_text)

            run_export(catalog_path, directory, new_language="en")
            en = XliffFile(os.path.join(directory, "en.xliff"))
            check(en.language == "en", label + ": export --new writes target-language")
            check(read(os.path.join(directory, FILE_LIST)) == "$(SRCROOT)/Translations/en.xliff\n",
                  label + ": file list names the XLIFF files")
            check(en.units["%lld mots|==|plural.one"]["target"] == "%lld word", label + ": plural unit exported")
            sub_id = "« %@ » contient %lld fichiers|==|substitutions.files.plural.other"
            check(en.units[sub_id]["source"] == "%2$lld fichiers", label + ": substitution uses %2$lld like Xcode")
            check(en.units["Nouveau"]["target"] == "" and en.units["Nouveau"]["state"] == "new",
                  label + ": untranslated string exported empty with state new")
            check(en.units["Enregistrer"]["notes"] == [(None, "Save button.")], label + ": comment exported as note")
            check(en.units["Ouvrir <fichier> & \"lien\""]["state"] == "needs-review-translation",
                  label + ": review state exported")

            changed = run_import(catalog_path, directory)
            check(not changed and read(catalog_path) == original_text, label + ": import right after export, no diff")

            catalog = Catalog(catalog_path)
            check(catalog.render() == original_text, label + ": catalog rewritten byte for byte")

            with open(os.path.join(directory, "es.xliff"), "w", encoding="utf-8") as handle:
                handle.write(ES_XLIFF)
            run_import(catalog_path, directory)
            data = json.loads(read(catalog_path))
            with_es = sorted(key for key, entry in data["strings"].items() if "es" in entry["localizations"])
            check(with_es == ["%lld mots", "Enregistrer"], label + ": es added for the translated strings only")
            check(data["strings"]["Enregistrer"]["localizations"]["es"]
                  == {"stringUnit": {"state": "translated", "value": "Guardar"}}, label + ": es simple string")
            check(data["strings"]["%lld mots"]["localizations"]["es"]["variations"]["plural"]["other"]["stringUnit"]
                  == {"state": "needs_review", "value": "%lld palabras"}, label + ": es plural with review state")
            for entry in data["strings"].values():
                entry["localizations"].pop("es", None)
            check(json.dumps(data, indent=2, ensure_ascii=False, separators=(",", separator))
                  + ("\n" if newline else "") == original_text,
                  label + ": nothing else changed, layout kept")

            with open(os.path.join(directory, "es.xliff"), "w", encoding="utf-8") as handle:
                handle.write(ES_XLIFF.replace("%lld palabras", "%lld palabras!"))
            before = read(catalog_path)
            run_import(catalog_path, directory)
            after = read(catalog_path)
            diff = [line for line in after.splitlines() if line not in before.splitlines()]
            check(len(diff) == 1 and "palabras!" in diff[0], label + ": a changed translation changes one line")

            translated = os.path.join(directory, "de.xliff")
            run_export(catalog_path, directory, new_language="de")
            text = read(translated).replace(
                '<source>« %1$@ » contient %2$#@files@</source>\n        <target state="new"></target>',
                '<source>« %1$@ » contient %2$#@files@</source>\n        <target state="translated">„%1$@“ enthält %2$#@files@</target>')
            text = text.replace('<source>%2$lld fichier</source>\n        <target state="new"></target>',
                                '<source>%2$lld fichier</source>\n        <target state="translated">%2$lld Datei</target>')
            text = text.replace('<source>%2$lld fichiers</source>\n        <target state="new"></target>',
                                '<source>%2$lld fichiers</source>\n        <target state="translated">%2$lld Dateien</target>')
            text = text.replace('<note>Save button.</note>',
                                '<note>Save button.</note>\n        <note from="translator">Imperative.</note>')
            with open(translated, "w", encoding="utf-8") as handle:
                handle.write(text)
            run_import(catalog_path, directory)
            data = json.loads(read(catalog_path))
            de = data["strings"]["« %@ » contient %lld fichiers"]["localizations"]["de"]
            check(de["stringUnit"]["value"] == "„%1$@“ enthält %#@files@", label + ": substitution token unnumbered on import")
            check(de["substitutions"]["files"]["variations"]["plural"]["other"]["stringUnit"]["value"] == "%arg Dateien"
                  and de["substitutions"]["files"]["argNum"] == 2, label + ": substitution imported back to %arg")

            catalog = Catalog(catalog_path)
            del catalog.strings["Nouveau"]
            put(catalog.strings, "Zut", {"localizations": {"fr": {"stringUnit": {"state": "translated", "value": "Zut"}}}})
            catalog.save_if_changed()
            run_export(catalog_path, directory)
            de_file = XliffFile(translated)
            check("Nouveau" not in de_file.units, label + ": export drops removed strings")
            check(de_file.units["Zut"]["target"] == "" and de_file.units["Zut"]["state"] == "new",
                  label + ": export adds new strings empty")
            check(("translator", "Imperative.") in de_file.units["Enregistrer"]["notes"],
                  label + ": translator note kept")
            check(de_file.units["%lld mots|==|plural.other"]["state"] == "new", label + ": export keeps plural forms")
            before = read(translated)
            run_export(catalog_path, directory)
            check(read(translated) == before, label + ": export is stable")

            run_export(catalog_path, directory, new_language="ja")
            run_export(catalog_path, directory, new_language="ru")
            ja = sorted(unit for unit in XliffFile(os.path.join(directory, "ja.xliff")).units if "mots|" in unit)
            ru = sorted(unit for unit in XliffFile(os.path.join(directory, "ru.xliff")).units if "mots|" in unit)
            check(ja == ["%lld mots|==|plural.other"], label + ": Japanese offers the plural form other only")
            check(ru == ["%lld mots|==|plural." + case for case in ("few", "many", "one", "other")],
                  label + ": Russian offers one, few, many and other")
            os.remove(os.path.join(directory, "ja.xliff"))
            os.remove(os.path.join(directory, "ru.xliff"))

        if real_catalog:
            root = os.path.join(work, "real")
            app = os.path.basename(os.path.dirname(real_catalog))
            os.makedirs(os.path.join(root, app))
            catalog_path = os.path.join(root, app, "Localizable.xcstrings")
            shutil.copyfile(real_catalog, catalog_path)
            directory = os.path.join(root, "Translations")
            real = Catalog(catalog_path)
            languages = catalog_languages(real) - {real.source_language}
            os.makedirs(directory)
            for language in sorted(languages):
                run_export(catalog_path, directory, new_language=language)
            run_import(catalog_path, directory)
            name = app + "/Localizable.xcstrings"
            check(read(catalog_path) == read(real_catalog), name + ": export then import leaves it unchanged")
            if real_translations and os.path.isdir(real_translations):
                run_import(catalog_path, real_translations, refresh_list=False)
                check(read(catalog_path) == read(real_catalog),
                      name + ": importing Translations/ leaves it unchanged")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print("{} failure(s)".format(len(failures)) if failures else "all passed")
    return 1 if failures else 0


# --------------------------------------------------------------------------

def default_catalog(root):
    found = sorted(glob.glob(os.path.join(root, "*", "Localizable.xcstrings")))
    if len(found) != 1:
        raise SystemExit("translations: expected one */Localizable.xcstrings in {}, found {}; use --catalog"
                         .format(root, len(found)))
    return found[0]


def main(arguments=None):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser = argparse.ArgumentParser(description="Sync Localizable.xcstrings with Translations/*.xliff.")
    parser.add_argument("command", choices=["import", "export", "selftest"])
    parser.add_argument("--catalog", help="the Localizable.xcstrings file")
    parser.add_argument("--translations", help="the folder of XLIFF files")
    parser.add_argument("--new", metavar="LANG", help="export: create the XLIFF file of a new language")
    options = parser.parse_args(arguments)

    catalog = os.path.abspath(options.catalog or default_catalog(root))
    directory = os.path.abspath(options.translations or os.path.join(root, "Translations"))
    if options.command == "selftest":
        return selftest(catalog, directory)
    if options.command == "import":
        run_import(catalog, directory)
    else:
        run_export(catalog, directory, options.new)
    return 0


if __name__ == "__main__":
    sys.exit(main())

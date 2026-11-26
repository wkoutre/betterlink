#!/usr/bin/env python3
"""Generates Sources/BetterlinkCore/TourRegistry.swift from Tour/tour.json, and
checks that the tour still covers the app.

Tour/tour.json lists every step of betterlink's tour: the first-run flow and
What's New are both drawn from it (docs/tour.md). Edit the steps there, then
run `make tour`. `make test` runs this with --check, which writes nothing and
fails when:

- the Swift file is out of date, or a step breaks the tour's writing rules;
- a page of the window, a setting's control, a group of commands or a macOS
  permission has no step (and no stated reason to have none);
- a step names a page, command or setting the app no longer has.

So a change that adds something a person sees or must allow can't merge
without its step. Everything is read from the source files as text, so the
check needs no build and runs anywhere Python does.
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Tour/tour.json"
OUT = ROOT / "Sources/BetterlinkCore/TourRegistry.swift"
APP = ROOT / "Sources/Betterlink"

# The writing rules, so every step reads like the others.
MAX_TITLE, MAX_BODY, MIN_BODY, MAX_SUMMARY, MAX_CHANGED = 48, 330, 60, 80, 160
# The first run asks for a few minutes at most.
MAX_ESSENTIAL_STEPS, MAX_TOPIC_STEPS = 6, 6

# What betterlink asks macOS or a browser for, and how to tell from the source
# that it still does. A permission whose sign is in the source needs a step; a
# step for one whose sign is gone is stale.
PERMISSIONS = {
    "default-browser": {"source": [r"setDefaultApplication\("]},
    "full-disk-access": {"source": [r"Privacy_AllFiles"]},
    "login-item": {"source": [r"\bSMAppService\b"]},
    "accessibility": {"source": [r"\bAXIsProcessTrusted"], "anchors": ["Privacy_Accessibility"]},
    "automation": {"source": [r"/usr/bin/osascript", r"\bNSAppleScript\b"],
                   "plist": ["NSAppleEventsUsageDescription"],
                   "entitlements": ["com.apple.security.automation.apple-events"],
                   "anchors": ["Privacy_Automation"]},
    "native-messaging": {"source": [r"NativeMessagingHosts"]},
    "browser-extension": {"source": [r"chrome://extensions"]},
    "files-and-folders": {"source": [r"\bNS(Open|Save)Panel\("]},
}
# What the Tabs extension asks the browser for (browser-extension/manifest.json).
# The browser shows these when the extension is added, and asks again when one
# is added later, so the step that has people add it says what it can see.
EXTENSION_ASKS = {"tabs", "nativeMessaging", "favicon", "storage"}
# Things macOS asks a person about that betterlink doesn't use today. One of
# these appearing in the source means a new prompt: give it an entry above and
# a step in Tour/tour.json.
NOT_ASKED_TODAY = {
    "screen recording": r"CGRequestScreenCaptureAccess|CGPreflightScreenCaptureAccess|SCShareableContent|CGWindowListCreateImage",
    "input monitoring": r"IOHIDRequestAccess|IOHIDCheckAccess|CGEvent\.tapCreate|CGEventTapCreate|addGlobalMonitorForEvents\(matching:[^)]*\.key",
    "notifications": r"UNUserNotificationCenter",
    "the camera or microphone": r"AVCaptureDevice",
    "location": r"CLLocationManager",
    "contacts": r"CNContactStore",
    "calendars or reminders": r"EKEventStore",
    "photos": r"PHPhotoLibrary",
    "Bluetooth": r"CBCentralManager",
    "the local network": r"\bNWBrowser\b|\bNetServiceBrowser\b|\bNWListener\b",
    "Touch ID or your password": r"\bLAContext\b",
    "speech recognition": r"SFSpeechRecognizer",
}
# Entitlements that change how the code runs and ask the user nothing.
SILENT_ENTITLEMENTS = {
    "com.apple.security.cs.allow-jit",
    "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.disable-executable-page-protection",
}
# The controls a setting is changed with. Each one's binding is a setting.
SETTING_CONTROLS = {
    "Toggle": "isOn", "Picker": "selection", "DSPicker": "selection", "ProfileMenu": "selection",
    "DSSwatchPicker": "color", "ShortcutRecorder": "shortcut",
    "Slider": "value", "Stepper": "value", "ColorPicker": "selection",
}

problems = []
def problem(text):
    problems.append(text)

def fatal(text):
    sys.exit(f"gen-tour: {text}")

def read(path):
    try:
        return path.read_text()
    except OSError as e:
        fatal(f"can't read {path.relative_to(ROOT)}: {e}")

# MARK: Reading Tour/tour.json

ID = re.compile(r"[a-z][a-z0-9]*(-[a-z0-9]+)*\Z")
NAME = re.compile(r"[a-z][A-Za-z0-9]*\Z")
STEP_KEYS = {"id", "revision", "title", "body", "changed", "status", "control", "requires", "cli", "cliWhy", "symbol", "covers"}
TOPIC_KEYS = {"id", "title", "summary", "symbol", "tile", "tier", "page", "requires", "steps"}
COVER_KEYS = {"pages", "commands", "permissions", "settings"}

def prose(where, text, most, least=1, sentence=True):
    """One piece of the tour's writing: plain, calm, and the length of its neighbours."""
    if not isinstance(text, str) or not text.strip():
        problem(f"{where} is empty."); return
    if text != text.strip() or "  " in text or "\n" in text or "\t" in text:
        problem(f"{where} has stray spaces or a line break.")
    if any(ord(c) < 0x20 for c in text):
        problem(f"{where} has a control character.")
    if len(text) > most:
        problem(f"{where} is {len(text)} characters; the most is {most}. Say less, or split the step.")
    if len(text) < least:
        problem(f"{where} is {len(text)} characters; a step explains itself in at least {least}.")
    if "—" in text or "–" in text or " - " in text or "--" in text:
        problem(f"{where} uses a dash as punctuation; write two sentences or use a comma.")
    if "!" in text:
        problem(f"{where} has an exclamation mark; the tour stays calm.")
    if sentence and not text.endswith((".", "?")):
        problem(f"{where} should end with a full stop.")
    if not sentence and text.endswith("."):
        problem(f"{where} is a title, so it has no full stop.")

def load():
    try:
        tour = json.loads(read(SRC))
    except json.JSONDecodeError as e:
        fatal(f"Tour/tour.json isn't valid JSON: {e}")
    if tour.get("version") != 1:
        fatal("Tour/tour.json: version must be 1.")
    topics = tour.get("topics")
    if not isinstance(topics, list) or not topics:
        fatal("Tour/tour.json: topics must be a list of topics.")
    seen_topics, seen_steps, essential = set(), set(), 0
    for t in topics:
        tid = t.get("id")
        where = f"Topic {tid!r}"
        if not isinstance(tid, str) or not ID.match(tid): fatal(f"{where}: id must be lower-case words joined by hyphens.")
        if tid in seen_topics: fatal(f"{where}: two topics have this id.")
        seen_topics.add(tid)
        for k in set(t) - TOPIC_KEYS: problem(f"{where} has an unknown key {k!r}.")
        prose(f"{where}'s title", t.get("title"), 28, sentence=False)
        prose(f"{where}'s summary", t.get("summary"), MAX_SUMMARY)
        if not isinstance(t.get("symbol"), str) or not t["symbol"]: problem(f"{where} needs a symbol (an SF Symbol name).")
        if not isinstance(t.get("tile"), str) or not NAME.match(t["tile"]): problem(f"{where} needs a tile: a colour from Design/tokens.json, in camel case.")
        if t.get("tier") not in ("essential", "more"): problem(f"{where}: tier is essential or more.")
        if t.get("page") is not None and not isinstance(t["page"], str): problem(f"{where}: page is a page's name or null.")
        if t.get("requires") is not None and not (isinstance(t["requires"], str) and NAME.match(t["requires"])):
            problem(f"{where}: requires is a condition's name in camel case.")
        steps = t.get("steps")
        if not isinstance(steps, list) or not steps: fatal(f"{where} has no steps.")
        if len(steps) > MAX_TOPIC_STEPS: problem(f"{where} has {len(steps)} steps; the most is {MAX_TOPIC_STEPS}. Split the topic.")
        if t.get("tier") == "essential": essential += len(steps)
        for s in steps:
            sid = s.get("id")
            at = f"Step {sid!r}"
            if not isinstance(sid, str) or not ID.match(sid): fatal(f"{at}: id must be lower-case words joined by hyphens.")
            if sid in seen_steps: fatal(f"{at}: two steps have this id. An id is what betterlink remembers a person saw, so it is never reused.")
            seen_steps.add(sid)
            for k in set(s) - STEP_KEYS: problem(f"{at} has an unknown key {k!r}.")
            rev = s.get("revision")
            if not isinstance(rev, int) or isinstance(rev, bool) or rev < 1: problem(f"{at}: revision is a whole number, 1 or more.")
            prose(f"{at}'s title", s.get("title"), MAX_TITLE, sentence=False)
            prose(f"{at}'s body", s.get("body"), MAX_BODY, MIN_BODY)
            if s.get("changed") is not None: prose(f"{at}'s changed", s["changed"], MAX_CHANGED)
            elif isinstance(rev, int) and rev > 1:
                problem(f"{at} is at revision {rev} with no \"changed\": say in a sentence what is different, for people who saw the earlier one.")
            for key in ("status", "control", "requires"):
                if s.get(key) is not None and not (isinstance(s[key], str) and NAME.match(s[key])):
                    problem(f"{at}: {key} is a name in camel case.")
            if s.get("symbol") is not None and not isinstance(s["symbol"], str): problem(f"{at}: symbol is an SF Symbol name.")
            cli, why = s.get("cli"), s.get("cliWhy")
            if cli is not None and not (isinstance(cli, str) and cli.startswith("betterlink ")):
                problem(f"{at}: cli is the command that does the same, starting with \"betterlink \".")
            if why is not None: prose(f"{at}'s cliWhy", why, 120)
            if cli is not None and why is not None: problem(f"{at} has both cli and cliWhy; keep one.")
            if s.get("status") is not None and s.get("control") is None:
                problem(f"{at} shows a status with nothing to act on; give it the control that changes that status.")
            if s.get("control") is not None and cli is None and why is None:
                problem(f"{at} lets a person change something, so it names the command that does the same (cli), or says why there is none (cliWhy).")
            covers = s.get("covers", {})
            if not isinstance(covers, dict): fatal(f"{at}: covers is an object.")
            for k in set(covers) - COVER_KEYS: problem(f"{at}: covers has an unknown key {k!r}.")
            for k, v in covers.items():
                if not isinstance(v, list) or not all(isinstance(x, str) for x in v): fatal(f"{at}: covers.{k} is a list of names.")
    if essential > MAX_ESSENTIAL_STEPS:
        problem(f"The essential topics have {essential} steps; the first run shows at most {MAX_ESSENTIAL_STEPS} before it lets people go. Move one to tier \"more\".")
    colours = {camel(c["name"]) for c in json.loads(read(ROOT / "Design/tokens.json"))["color"]["tokens"]}
    for t in topics:
        if isinstance(t.get("tile"), str) and t["tile"] not in colours:
            problem(f"Topic {t['id']!r}: tile {t['tile']!r} isn't a colour in Design/tokens.json.")
    # Ids of steps that were removed. betterlink remembers a step by its id,
    # so one that was shown once is never used again for another step
    # (scripts/check-tour-pr.py makes a removed step's id land here).
    retired = tour.get("retired", [])
    if not isinstance(retired, list) or not all(isinstance(r, str) and ID.match(r) for r in retired):
        problem("retired is a list of step ids.")
    else:
        if len(set(retired)) != len(retired): problem("retired lists an id twice.")
        for r in retired:
            if r in seen_steps: problem(f"Step {r!r} uses a retired id. Give the step a new id: betterlink may remember the old one as seen.")
    exempt = tour.get("exempt", {})
    for k in ("pages", "commands", "settings"):
        for name, why in exempt.get(k, {}).items():
            prose(f"The reason {name!r} has no step", why, 200, 20)
    for k in set(exempt) - {"pages", "commands", "settings"}: problem(f"exempt has an unknown key {k!r}.")
    return tour

def camel(name):
    """tile-ink -> tileInk, as scripts/gen-tokens.py names a token in Swift."""
    first, *rest = name.split("-")
    return first + "".join(w.capitalize() for w in rest)

def steps_of(tour):
    for t in tour["topics"]:
        for s in t["steps"]:
            yield t, s

def covered(tour, kind):
    """name -> the step ids that cover it."""
    out = {}
    for _, s in steps_of(tour):
        for name in s.get("covers", {}).get(kind, []):
            out.setdefault(name, []).append(s["id"])
    return out

# MARK: Writing the Swift file

def lit(s):
    return "nil" if s is None else json.dumps(s, ensure_ascii=False)

def case(name):
    return "nil" if name is None else f".{name}"

def names(tour, key, topics=False):
    found = []
    for t, s in steps_of(tour):
        for v in ([t.get(key)] if topics else []) + [s.get(key)]:
            if v is not None and v not in found: found.append(v)
    return found

def enum(out, name, doc, cases):
    out.append(f"/// {doc}")
    out.append(f"public enum {name}: String, CaseIterable, Sendable {{")
    for c in cases: out.append(f"    case {c}")
    out.append("}")
    out.append("")

def generate(tour):
    out = ["// Generated from Tour/tour.json by scripts/gen-tour.py. Do not edit.",
           "// Change the steps there and run `make tour`.", "",
           "// The names the steps use. The app draws each control, reads each status and",
           "// colours each tile with a switch over these, so a name the app doesn't know",
           "// yet stops the build instead of showing an empty step.", ""]
    enum(out, "TourControl", "What a step gives the person to act on: a button, a switch, a small form.", names(tour, "control"))
    enum(out, "TourProbe", "What a step shows as done or not yet: a permission, a setting, a connection.", names(tour, "status"))
    enum(out, "TourCondition", "What this Mac needs for a step to apply.", names(tour, "requires", topics=True))
    tiles = []
    for t in tour["topics"]:
        if t["tile"] not in tiles: tiles.append(t["tile"])
    enum(out, "TourTile", "The colour behind a topic's symbol, by its name in Design/tokens.json.", tiles)
    out.append("public enum TourRegistry {")
    out.append("    /// Every topic and step, in the order the tour shows them.")
    out.append("    public static let topics: [TourTopic] = [")
    for t in tour["topics"]:
        out.append(f"        TourTopic(id: {lit(t['id'])}, title: {lit(t['title'])},")
        out.append(f"                  summary: {lit(t['summary'])},")
        out.append(f"                  symbol: {lit(t['symbol'])}, tile: .{t['tile']}, tier: .{t['tier']}, page: {lit(t.get('page'))}, steps: [")
        for s in t["steps"]:
            requires = s.get("requires") or t.get("requires")
            out.append(f"            TourStep(id: {lit(s['id'])}, revision: {s['revision']},")
            out.append(f"                     title: {lit(s['title'])},")
            out.append(f"                     body: {lit(s['body'])},")
            out.append(f"                     changed: {lit(s.get('changed'))}, symbol: {lit(s.get('symbol') or t['symbol'])},")
            out.append(f"                     status: {case(s.get('status'))}, control: {case(s.get('control'))}, requires: {case(requires)},")
            out.append(f"                     cli: {lit(s.get('cli'))}, cliWhy: {lit(s.get('cliWhy'))}),")
        out.append("        ]),")
    out.append("    ]")
    out.append("}")
    return "\n".join(out) + "\n"

# MARK: What the app has

def swift_sources(folder, skip_tour=True):
    for p in sorted(folder.rglob("*.swift")):
        rel = p.relative_to(ROOT).as_posix()
        # The tour's own files describe the app; they aren't what is described.
        if skip_tour and (p.name.startswith("Tour") or "/Tour/" in rel): continue
        yield p, read(p)

def app_pages():
    """The window's pages, by the names they are saved under (RootView.Page)."""
    text = read(APP / "RootView.swift")
    m = re.search(r"enum Page\s*:\s*String[^{]*\{(.*?)\n\s*var ", text, re.S)
    if not m: fatal("couldn't find `enum Page: String` in Sources/Betterlink/RootView.swift. If the pages moved, teach scripts/gen-tour.py where they are.")
    pages = []
    for line in m.group(1).splitlines():
        line = line.split("//")[0].strip()
        if not line.startswith("case "): continue
        for part in line[5:].split(","):
            bits = part.strip().split("=")
            raw = bits[1].strip().strip('"') if len(bits) > 1 else bits[0].strip()
            if raw: pages.append(raw)
    if not pages: fatal("found `enum Page` but no pages in it.")
    return pages

def command_group(command):
    """rules.add -> rules; sidebar.profiles.add -> sidebar.profiles; status -> status."""
    return command.rsplit(".", 1)[0] if "." in command else command

def app_commands():
    """Every agent command (what the betterlink CLI calls), from the lists in the source."""
    commands = []
    for _, text in swift_sources(ROOT / "Sources", skip_tour=False):
        for m in re.finditer(r"static let \w*[cC]ommands\b\s*(?::\s*\[String\])?\s*=\s*\[(.*?)\]", text, re.S):
            commands += re.findall(r'"([a-z][a-z0-9.-]*)"', m.group(1))
    if len(commands) < 20:
        fatal(f"found only {len(commands)} agent commands. If the command lists moved, teach scripts/gen-tour.py where they are.")
    return sorted(set(commands))

def call_arguments(text, start):
    """The text between the parenthesis at `start` and the one that closes it."""
    depth, i = 0, start
    while i < len(text) and i < start + 1200:
        c = text[i]
        if c == "(": depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0: return text[start + 1:i]
        i += 1
    return text[start + 1:i]

def app_settings():
    """Every control that changes a setting, as File.binding (Pages.model.showLog)."""
    found = {}
    kinds = "|".join(SETTING_CONTROLS)
    for path, text in swift_sources(APP):
        if path.name == "Controls.swift": continue  # where the controls are made, not used
        for m in re.finditer(rf"(?<![\w.])({kinds})\(", text):
            # A declaration (`struct ShortcutRecorder: View`, `init(`) has no call here.
            label = SETTING_CONTROLS[m.group(1)]
            args = call_arguments(text, m.end() - 1)
            b = re.search(rf"\b{label}\s*:\s*(?:\$([\w.]+)|Binding\(\s*get:\s*\{{\s*([\w.?]+)|([\w.]+))", args)
            line = text.count("\n", 0, m.start()) + 1
            where = f"{path.relative_to(ROOT).as_posix()}:{line}"
            if not b:
                fatal(f"{where}: a {m.group(1)} with no `{label}:` this script can read. Teach scripts/gen-tour.py its shape.")
            # A second control in the file bound to the same name (a local
            # `on`, say) is another setting: it gets its own name, #2.
            key, n = f"{path.stem}.{b.group(1) or b.group(2) or b.group(3)}", 1
            while (key if n == 1 else f"{key}#{n}") in found: n += 1
            found[key if n == 1 else f"{key}#{n}"] = where
    if len(found) < 5:
        fatal("found almost no setting controls. If the pages moved, teach scripts/gen-tour.py where they are.")
    return found

def app_permissions():
    """permission -> where the source shows betterlink asks for it."""
    # The tour's own files too: a step's control can be what asks.
    sources = list(swift_sources(ROOT / "Sources", skip_tour=False))
    plist = read(ROOT / "Info.plist")
    usage = set(re.findall(r"<key>(NS\w+UsageDescription)</key>", plist))
    entitlements = set()
    for f in sorted((ROOT / "scripts").glob("*.entitlements")):
        entitlements |= set(re.findall(r"<key>([\w.-]+)</key>", read(f)))
    anchors = {}
    for path, text in sources:
        # The pane's name wherever it is written, so a link put together from
        # parts counts too.
        for m in re.finditer(r"x-apple\.systempreferences:[\w.]+\?(\w+)|\b(Privacy_\w+)", text):
            anchors[m.group(1) or m.group(2)] = path.relative_to(ROOT).as_posix()
    asked = {}
    for name, signs in PERMISSIONS.items():
        for path, text in sources:
            for pattern in signs.get("source", []):
                if re.search(pattern, text):
                    asked.setdefault(name, path.relative_to(ROOT).as_posix())
        for key in signs.get("plist", []):
            if key in usage: asked.setdefault(name, "Info.plist")
        for key in signs.get("entitlements", []):
            if key in entitlements: asked.setdefault(name, "scripts/*.entitlements")
    known_usage = {k for s in PERMISSIONS.values() for k in s.get("plist", [])}
    for key in sorted(usage - known_usage):
        problem(f"Info.plist has {key}, a reason macOS shows when it asks the user for something, and the tour doesn't know it. "
                "Add it to PERMISSIONS in scripts/gen-tour.py and give it a step in Tour/tour.json.")
    known_entitlements = {k for s in PERMISSIONS.values() for k in s.get("entitlements", [])} | SILENT_ENTITLEMENTS
    for key in sorted(entitlements - known_entitlements):
        problem(f"An entitlements file has {key}, which the tour doesn't know. If it makes macOS ask the user for something, add it to "
                "PERMISSIONS in scripts/gen-tour.py with a step; if it asks nothing, add it to SILENT_ENTITLEMENTS.")
    known_anchors = {"Privacy_AllFiles"} | {a for s in PERMISSIONS.values() for a in s.get("anchors", [])}
    for anchor, where in sorted(anchors.items()):
        if anchor not in known_anchors:
            problem(f"{where} opens System Settings at {anchor}, a permission the tour doesn't know. Add it to PERMISSIONS in "
                    "scripts/gen-tour.py and give it a step in Tour/tour.json.")
    try:
        manifest = json.loads(read(ROOT / "browser-extension/manifest.json"))
    except json.JSONDecodeError as e:
        fatal(f"browser-extension/manifest.json isn't valid JSON: {e}")
    asks = set()
    for key in ("permissions", "optional_permissions", "host_permissions", "optional_host_permissions"):
        asks |= set(manifest.get(key, []))
    for scripts in manifest.get("content_scripts", []):
        asks |= set(scripts.get("matches", []))
    for extra in sorted(asks - EXTENSION_ASKS):
        problem(f"browser-extension/manifest.json now asks the browser for {extra!r}. The browser tells people when they add or update the "
                "extension, so say what it is for in the step that covers the browser-extension permission, then add it to EXTENSION_ASKS "
                "in scripts/gen-tour.py.")
    for gone in sorted(EXTENSION_ASKS - asks):
        problem(f"EXTENSION_ASKS in scripts/gen-tour.py lists {gone!r}, which browser-extension/manifest.json no longer asks for. Remove it, "
                "and anything the step says about it.")
    for what, pattern in NOT_ASKED_TODAY.items():
        for path, text in sources:
            if re.search(pattern, text):
                problem(f"{path.relative_to(ROOT).as_posix()} uses an API that makes macOS ask for {what}, which betterlink has never asked for. "
                        "Add it to PERMISSIONS in scripts/gen-tour.py and give it a step in Tour/tour.json that says why first.")
                break
    return asked

def balanced(text, start):
    """The text of the expression starting at `start`, up to the comma or closing bracket that ends it."""
    depth, i, quote = 0, start, None
    while i < len(text):
        c = text[i]
        if quote:
            if c == "\\": i += 1
            elif c == quote: quote = None
        elif c in "'\"`": quote = c
        elif c in "({[": depth += 1
        elif c in ")}]":
            if depth == 0: break
            depth -= 1
        elif c == "," and depth == 0: break
        i += 1
    return text[start:i]

def object_keys(expression, shared):
    """The option names in `z.object({ a: …, b, ...c })`, `z.object(c)` or `c`."""
    expression = expression.strip()
    m = re.match(r"(?:z\.object\(\s*)?(\w+)\s*\)?\s*\Z", expression)
    if m: return set(shared.get(m.group(1), ()))
    brace = expression.find("{")
    if brace < 0: return set()
    keys, i = set(), brace + 1
    while i < len(expression):
        entry = balanced(expression, i)
        word = entry.strip()
        if word.startswith("..."): keys |= set(shared.get(word[3:].strip(), ()))
        else:
            m = re.match(r"(\w+)", word)
            if m: keys.add(m.group(1))
        i += len(entry) + 1
        if i - 1 < len(expression) and expression[i - 1] in ")}]": break
    return keys

def cli_commands():
    """Every command of the betterlink CLI with its options: {"rules add": {"kind", "pattern", …}}."""
    text = read(ROOT / "cli/src/bin.ts")
    # Options kept in a shared object (`const profileOptions = {…}`, `const tabId = z.object({…})`).
    shared = {}
    for m in re.finditer(r"^const (\w+) = ((?:z\.object\()?\{)", text, re.M):
        shared[m.group(1)] = object_keys(balanced(text, m.start(2)), shared)
    blocks = {}
    starts = list(re.finditer(r"^(?:export )?const (\w+) = Cli\.create\('([^']+)'", text, re.M))
    for i, m in enumerate(starts):
        end = starts[i + 1].start() if i + 1 < len(starts) else len(text)
        blocks[m.group(1)] = (m.group(2), text[m.start():end])
    if "cli" not in blocks: fatal("couldn't find `const cli = Cli.create(` in cli/src/bin.ts.")
    out = {}
    def walk(var, prefix):
        _, body = blocks[var]
        subs = list(re.finditer(r"^\s*\.command\((?:'([^']+)'|(\w+))", body, re.M))
        for j, s in enumerate(subs):
            if s.group(2):
                if s.group(2) in blocks: walk(s.group(2), prefix + [blocks[s.group(2)][0]])
                continue
            chunk = body[s.start():subs[j + 1].start() if j + 1 < len(subs) else len(body)]
            o = re.search(r"\boptions:\s*", chunk)
            out[" ".join(prefix + [s.group(1)])] = object_keys(balanced(chunk, o.end()), shared) if o else set()
    walk("cli", [])
    if len(out) < 20: fatal(f"found only {len(out)} commands in cli/src/bin.ts. If its shape changed, teach scripts/gen-tour.py to read it.")
    return out

# MARK: Checking the tour against the app

def check_coverage(tour):
    exempt = tour.get("exempt", {})

    def compare(kind, have, plural, how):
        cover, skip = covered(tour, kind), exempt.get(kind, {})
        for name in have:
            if name not in cover and name not in skip:
                problem(f"{plural[0].upper()}{plural[1:]} {name!r} has no step in Tour/tour.json. {how}")
            if name in cover and name in skip:
                problem(f"{name!r} has a step and is also listed under exempt.{kind}; keep one.")
        for name, ids in cover.items():
            if name not in have:
                problem(f"Step {ids[0]!r} covers the {plural} {name!r}, which betterlink no longer has. Update or remove it.")
        for name in skip:
            if name not in have:
                problem(f"exempt.{kind} lists {name!r}, which betterlink no longer has. Remove it.")

    pages = app_pages()
    compare("pages", pages, "page",
            "Add a step that says what the page is for (covers.pages), or list it under exempt.pages with the reason it needs none.")
    for t in tour["topics"]:
        if t.get("page") is not None and t["page"] not in pages:
            problem(f"Topic {t['id']!r} points at the page {t['page']!r}, which the window doesn't have.")

    groups = sorted({command_group(c) for c in app_commands()})
    compare("commands", groups, "command group",
            "The command line can do everything the window can, so a new group of commands is a new feature: add a step for it "
            "(covers.commands), or list it under exempt.commands with the reason.")

    settings = app_settings()
    cover, skip = covered(tour, "settings"), exempt.get("settings", {})
    for name, where in sorted(settings.items()):
        if name not in cover and name not in skip:
            problem(f"{where}: the setting {name!r} has no step in Tour/tour.json. Add it to the step that introduces it (covers.settings), "
                    "write a new step, or list it under exempt.settings with the reason.")
    for name, ids in cover.items():
        if name not in settings:
            problem(f"Step {ids[0]!r} covers the setting {name!r}, which no page has any more. Update or remove it.")
    for name in skip:
        if name not in settings: problem(f"exempt.settings lists {name!r}, which no page has any more. Remove it.")

    asked = app_permissions()
    cover = covered(tour, "permissions")
    for name, where in sorted(asked.items()):
        if name not in cover:
            problem(f"betterlink asks for {name} ({where}) and no step in Tour/tour.json walks the person through it. "
                    "Add a step that says why before the prompt (covers.permissions).")
    for name, ids in cover.items():
        if name not in PERMISSIONS:
            problem(f"Step {ids[0]!r} covers the permission {name!r}, which scripts/gen-tour.py doesn't know. Add it to PERMISSIONS there.")
        elif name not in asked:
            problem(f"Step {ids[0]!r} covers the permission {name!r}, and nothing in the source asks for it any more. Update or remove it.")

    commands = cli_commands()
    for _, s in steps_of(tour):
        if not s.get("cli"): continue
        words = s["cli"].split()[1:]
        path = []
        for w in words:
            if w.startswith("-") or " ".join(path) in commands: break
            path.append(w)
        name = " ".join(path)
        if name not in commands:
            problem(f"Step {s['id']!r} says to run `{s['cli']}`, and the command line has no `betterlink {name}`.")
            continue
        for option in re.findall(r"--([A-Za-z][\w-]*)", s["cli"]):
            if option not in commands[name]:
                problem(f"Step {s['id']!r} says to run `{s['cli']}`, and `betterlink {name}` has no --{option}.")

def main():
    tour = load()
    text = generate(tour)
    check_coverage(tour)
    if "--check" in sys.argv:
        if not OUT.exists() or OUT.read_text() != text:
            problem("Sources/BetterlinkCore/TourRegistry.swift is out of date; run `make tour`.")
    elif not problems:
        OUT.write_text(text)
        print(f"wrote {OUT.relative_to(ROOT)}")
    if problems:
        print("gen-tour: the tour and the app disagree (docs/tour.md says how the tour is kept).", file=sys.stderr)
        for p in problems: print(f"  - {p}", file=sys.stderr)
        sys.exit(1)

main()

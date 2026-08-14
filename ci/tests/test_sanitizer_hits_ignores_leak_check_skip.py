"""The `sanitizer_hits` detector must ignore safeExit()'s leak-check-skip notice.

`ClickHouseProc.check_fatal_messages_in_logs` scans the server's stderr for
sanitizer output: `rg -z` matches the lines `FuzzerLogParser` can classify
(`SANITIZER_ERROR_PATTERN` for a report that names a sanitizer,
`RUNTIME_ERROR_PATTERN` for the bare `runtime error:` UBSan prints), then removes
a closed allow-list of benign lines. Whatever survives `head -n 1` becomes a
`BLOCKER` job failure.

`safeExit()` writes `Not running the leak check: other threads are still
running.` when a forced shutdown skips the LeakSanitizer check. That notice
records a check that was *skipped*, so it can never itself be a report - but it
is not sanitizer output either, and it used to get blamed as a sanitizer hit:
the detector opened an *open-ended* `sed` range at the first line containing
`anitizer` - benignly, at the `__asan_handle_no_return` block's
`For details see https://github.com/google/sanitizers/issues/189` - and the
notice then survived the allow-list applied after the range had opened.

Matching the parser's patterns instead of a range means the notice is not matched
at all, so the allow-list is now a safety net rather than the only guard, and
arms 1, 3 and 4 hold because nothing matches rather than because a filter fired.
The arms still drive the real pipeline, extracted from the module's source so
that editing the pipeline breaks this test rather than silently bypassing it.
Arms 2, 2b and 5 pin what the detector must still blame. Arm 5b is the one that
stays load-bearing for the filter: a report sharing a line with the notice does
match, and only a whole-line filter keeps it. Arm 4 covers the multi-server
layout, where `stderr*.log*` globs to several files.

The notice text itself lives in three places - `safeExit.cpp` writes it, the
pipeline filters it, and the arms below feed it - and the whole-line match only
works while all three agree. So the arms derive it from `safeExit.cpp` and
`test_ci_filter_matches_the_emitted_notice` holds the filter to the same source.
"""

import ast
import re
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PROC_PY = REPO_ROOT / "ci" / "jobs" / "scripts" / "clickhouse_proc.py"
PARSER_PY = REPO_ROOT / "ci" / "jobs" / "scripts" / "log_parser.py"
SAFE_EXIT_CPP = REPO_ROOT / "base" / "base" / "safeExit.cpp"


def _extract_skip_notice() -> str:
    """The notice `safeExit()` writes, taken from the C++ that writes it.

    Derived rather than copied so that the arms below drive the line the server
    really emits; the filter is pinned to the same source in
    `test_ci_filter_matches_the_emitted_notice`.
    """
    literals = re.findall(
        r'static\s+constexpr\s+char\s+message\[\]\s*=\s*"((?:[^"\\]|\\.)*)"\s*;',
        SAFE_EXIT_CPP.read_text(),
    )
    assert (
        len(literals) == 1
    ), f"expected one message[] literal in {SAFE_EXIT_CPP}, got {len(literals)}"
    # The escapes `safeExit.cpp` uses (`\n`) mean the same in both languages, and
    # `literal_eval` rejects anything it cannot read rather than guessing.
    return ast.literal_eval(f'"{literals[0]}"')


SKIP_NOTICE_LINE = _extract_skip_notice()
SKIP_NOTICE = SKIP_NOTICE_LINE.rstrip("\n")

# The `__asan_handle_no_return` block, verbatim. Its 3rd line is what opens the
# `sed` range; all four are on the detector's allow-list.
ASAN_STACK_SIZE_BLOCK = [
    "==1==WARNING: ASan is ignoring requested __asan_handle_no_return: stack top: 0x7f0000000000; bottom 0x7ffd00000000; size: 0x000300000000 (12884901888)",
    "False positive error reports may follow",
    "For details see https://github.com/google/sanitizers/issues/189",
    "==1==WARNING: ASan doesn't fully support makecontext/swapcontext functions and may produce false positives in some cases!",
]

REAL_REPORT = "==1==ERROR: LeakSanitizer: detected memory leaks"


def _single_assignment(tree: ast.Module, name: str) -> ast.expr:
    """The value assigned to `name`, when the module assigns it exactly once."""
    assigns = [
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.Assign)
        and any(
            isinstance(target, ast.Name) and target.id == name
            for target in node.targets
        )
    ]
    assert len(assigns) == 1, f"expected one {name} assignment, got {len(assigns)}"
    return assigns[0].value


def _class_attribute(module_path: Path, class_name: str, attribute: str) -> str:
    """A string constant defined in a class body, read from source.

    Read rather than imported, for the same reason as the pipeline below.
    """
    tree = ast.parse(module_path.read_text())
    for node in ast.walk(tree):
        if not isinstance(node, ast.ClassDef) or node.name != class_name:
            continue
        for statement in node.body:
            if isinstance(statement, ast.Assign) and any(
                isinstance(target, ast.Name) and target.id == attribute
                for target in statement.targets
            ):
                # Adjacent string literals are one Constant by the time we see them.
                return ast.literal_eval(statement.value)
    raise AssertionError(f"{class_name}.{attribute} not found in {module_path}")


def _resolve_sanitizer_pattern(tree: ast.Module) -> str:
    """The trigger regex, reassembled from the `sanitizer_pattern` assignment.

    Its halves live on `FuzzerLogParser` so that the detector fires on exactly what
    the parser can classify; they are read from `log_parser.py` here rather than
    copied, because a copy would let the two drift apart - which is the bug this
    interpolation exists to prevent.
    """
    joined = _single_assignment(tree, "sanitizer_pattern")
    assert isinstance(
        joined, ast.JoinedStr
    ), "sanitizer_pattern is no longer an f-string"
    parts = []
    for value in joined.values:
        if isinstance(value, ast.Constant):
            parts.append(value.value)
            continue
        expr = ast.unparse(value.value)
        attribute = re.fullmatch(r"FuzzerLogParser\.(\w+)", expr)
        assert attribute, f"unexpected interpolation {expr!r} in sanitizer_pattern"
        parts.append(_class_attribute(PARSER_PY, "FuzzerLogParser", attribute.group(1)))
    return "".join(parts)


def _extract_sanitizer_hits_pipeline() -> str:
    """The `sanitizer_hits` shell pipeline, taken from the module's own source.

    Read rather than imported: importing `clickhouse_proc` pulls in the whole
    praktika stack. The f-string is reassembled from the AST so a paraphrase
    cannot creep in, `{self.log_dir}` becomes `${LOG_DIR}`, and the trigger regex
    is resolved to what the parser actually defines.
    """
    tree = ast.parse(PROC_PY.read_text())
    call = _single_assignment(tree, "sanitizer_hits")
    assert isinstance(
        call, ast.Call
    ), "sanitizer_hits is no longer a Shell.get_output() call"
    joined = call.args[0]
    assert isinstance(
        joined, ast.JoinedStr
    ), "sanitizer_hits argument is no longer an f-string"

    parts = []
    for value in joined.values:
        if isinstance(value, ast.Constant):
            parts.append(value.value)
            continue
        expr = ast.unparse(value.value)
        if expr == "self.log_dir":
            parts.append("${LOG_DIR}")
        elif expr == "sanitizer_pattern":
            parts.append(_resolve_sanitizer_pattern(tree))
        else:
            raise AssertionError(f"unexpected interpolation {expr!r} in the pipeline")
    return "".join(parts)


PIPELINE = _extract_sanitizer_hits_pipeline()


def _detect(log_dir: Path) -> str:
    """Run the detector over `log_dir` and return what it would blame."""
    completed = subprocess.run(
        ["bash", "-c", f"LOG_DIR={log_dir}; " + PIPELINE],
        capture_output=True,
        text=True,
        check=False,
    )
    assert completed.returncode == 0, completed.stderr
    return completed.stdout.strip()


def _write(log_dir: Path, **files) -> None:
    for name, lines in files.items():
        (log_dir / name).write_text("".join(line + "\n" for line in lines))


def test_ci_filter_matches_the_emitted_notice():
    """The filter is a whole-line match, so it must equal the emitted line exactly."""
    filters = re.findall(r'grep -a -v -F -x "([^"]*)"', PIPELINE)
    assert (
        len(filters) == 1
    ), f"expected one -F -x filter in the pipeline, got {filters}"
    assert filters[0] == SKIP_NOTICE, (
        f"the leak-check-skip notice differs between\n"
        f"  {SAFE_EXIT_CPP} (writes {SKIP_NOTICE_LINE!r})\n"
        f"  {PROC_PY} (filters {filters[0]!r})\n"
        f"`grep -F -x` matches whole lines, so the filter stops matching and the "
        f"notice becomes a BLOCKER sanitizer hit. Update both."
    )


def test_pipeline_filters_the_skip_notice(tmp_path):
    """Arm 1: the notice alone, behind a benignly opened range, is not a hit."""
    _write(tmp_path, **{"stderr.log": ASAN_STACK_SIZE_BLOCK + [SKIP_NOTICE]})
    assert _detect(tmp_path) == ""


def test_pipeline_still_reports_a_real_leak(tmp_path):
    """Arm 2: a genuine report is still blamed.

    This is the arm that proves the filter is not a blanket silencer, so it is
    written in the ordering CI actually produces - `safeExit()` writes the
    notice immediately before `_exit()`, so a real report always precedes it -
    and it must hold both with and without the filter.
    """
    _write(
        tmp_path,
        **{"stderr.log": ASAN_STACK_SIZE_BLOCK + [REAL_REPORT, SKIP_NOTICE]},
    )
    assert _detect(tmp_path) == REAL_REPORT


def test_pipeline_reports_a_real_leak_the_notice_would_shadow(tmp_path):
    """Arm 2b: a report *after* the notice is blamed, rather than the notice.

    No single process emits this ordering, but the detector globs `stderr*.log*`,
    so several servers' files are searched as one run (the layout arm 4 covers):
    server A's notice can precede server B's report. The detector's output is
    order-sensitive (`head -n 1`), so anything blamed ahead of the report hides it.
    """
    _write(
        tmp_path,
        **{"stderr.log": ASAN_STACK_SIZE_BLOCK + [SKIP_NOTICE, REAL_REPORT]},
    )
    assert _detect(tmp_path) == REAL_REPORT


def test_pipeline_ignores_the_asan_stack_size_block_alone(tmp_path):
    """Arm 3: the allow-listed block on its own is not a hit (unchanged behaviour)."""
    _write(tmp_path, **{"stderr.log": ASAN_STACK_SIZE_BLOCK})
    assert _detect(tmp_path) == ""


def test_pipeline_filters_the_skip_notice_across_stderr_files(tmp_path):
    """Arm 4: multi-server layout - benign block in one file, the notice in the next.

    `stderr*.log*` globs to several files on a multi-server run (e.g.
    DatabaseReplicated), which used to carry the open `sed` range from
    `stderr.log` into `stderr1.log` and blame the notice there. `stderr1.log`
    holds nothing but the notice: any other line there would be blamed first
    (nothing else the server prints is allow-listed) and would mask what this arm
    measures.
    """
    _write(
        tmp_path,
        **{
            "stderr.log": ASAN_STACK_SIZE_BLOCK,
            "stderr1.log": [SKIP_NOTICE],
        },
    )
    assert _detect(tmp_path) == ""


def test_pipeline_does_not_over_match_the_skip_notice(tmp_path):
    """Arm 5: a lookalike differing *before* the notice's text is not filtered."""
    lookalike = f"Not running the leak check for real: {REAL_REPORT}"
    _write(tmp_path, **{"stderr.log": ASAN_STACK_SIZE_BLOCK + [lookalike]})
    assert _detect(tmp_path) == lookalike


def test_pipeline_reports_a_leak_sharing_a_line_with_the_notice(tmp_path):
    """Arm 5b: a report that *contains* the notice is still blamed.

    A substring filter drops any line merely containing the notice, which
    silently loses this report - the whole-line match is what keeps it. The
    notice can only ever be a complete line (`safeExit()` writes one fixed
    buffer, newline included, in a single `write(2)`), so matching the whole
    line costs no coverage.
    """
    shared = f"{REAL_REPORT} {SKIP_NOTICE}"
    _write(tmp_path, **{"stderr.log": ASAN_STACK_SIZE_BLOCK + [shared]})
    assert _detect(tmp_path) == shared

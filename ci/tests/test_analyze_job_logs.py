import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../.."))

from ci.jobs.ast_fuzzer_job import _classify_sanitizer_oom
from ci.jobs.lacasadeldolor_job import collapse_server_exit_code

_OOM_LINE = "==1==ERROR: AddressSanitizer: out-of-memory: allocator is trying to allocate 0x100 bytes\n"
_TSAN_CRASH = "==2==ERROR: ThreadSanitizer: data race on 0xdeadbeef\n"
_SEGV_CRASH = "==1==ERROR: AddressSanitizer: SEGV on unknown address 0x000000000000\n"


def _server_log(tmp_path, name, text):
    p = tmp_path / name
    p.write_text(text, encoding="utf-8")
    return p


def test_pure_sanitizer_oom_is_success(tmp_path):
    log = _server_log(tmp_path, "server0.log", _OOM_LINE)
    is_oom_success, messages = _classify_sanitizer_oom(
        [log], [], server_died=True, server_exit_code=0, workspace_path=tmp_path
    )
    assert is_oom_success is True
    assert any("Sanitizer OOM on server 0" in m for m in messages)


def test_mixed_oom_and_real_crash_on_same_node_is_failure(tmp_path):
    # A node log with both an OOM marker and a genuine ThreadSanitizer crash must
    # not be downgraded to success (the bug fixed for this review).
    log = _server_log(tmp_path, "server0.log", _OOM_LINE + _TSAN_CRASH)
    is_oom_success, messages = _classify_sanitizer_oom(
        [log], [], server_died=True, server_exit_code=0, workspace_path=tmp_path
    )
    assert is_oom_success is False
    assert messages == []


def test_pure_non_oom_crash_is_failure(tmp_path):
    log = _server_log(tmp_path, "server0.log", _SEGV_CRASH)
    is_oom_success, _ = _classify_sanitizer_oom(
        [log], [], server_died=True, server_exit_code=0, workspace_path=tmp_path
    )
    assert is_oom_success is False


def test_multi_node_oom_plus_other_node_crash_is_failure(tmp_path):
    # One node OOMs, another node has a real crash: the run must fail, not be
    # reported as OOM-only success.
    oom_node = _server_log(tmp_path, "server0.log", _OOM_LINE)
    crash_node = _server_log(tmp_path, "server1.log", _TSAN_CRASH)
    is_oom_success, _ = _classify_sanitizer_oom(
        [oom_node, crash_node],
        [],
        server_died=True,
        server_exit_code=0,
        workspace_path=tmp_path,
    )
    assert is_oom_success is False


def test_kernel_oom_kill_without_sanitizer_report_is_success(tmp_path):
    # SIGKILL (exit 137) with a clean log and no sanitizer.log.* is an OOM.
    log = _server_log(tmp_path, "server0.log", "2026.01.01 Application: started\n")
    is_oom_success, messages = _classify_sanitizer_oom(
        [log], [], server_died=True, server_exit_code=137, workspace_path=tmp_path
    )
    assert is_oom_success is True
    assert any("kernel OOM killer" in m for m in messages)


def test_kernel_oom_kill_with_sanitizer_report_is_not_downgraded(tmp_path):
    # A sanitizer report present alongside the SIGKILL means the kill was not a
    # plain kernel OOM, so it must not be downgraded on that heuristic alone.
    log = _server_log(tmp_path, "server0.log", "2026.01.01 Application: started\n")
    (tmp_path / "sanitizer.log.1234").write_text("some report", encoding="utf-8")
    is_oom_success, _ = _classify_sanitizer_oom(
        [log], [], server_died=True, server_exit_code=137, workspace_path=tmp_path
    )
    assert is_oom_success is False


def test_clean_log_is_not_oom_success(tmp_path):
    log = _server_log(tmp_path, "server0.log", "2026.01.01 Application: started\n")
    is_oom_success, _ = _classify_sanitizer_oom(
        [log], [], server_died=False, server_exit_code=0, workspace_path=tmp_path
    )
    assert is_oom_success is False


def test_oom_report_only_in_stderr_is_found(tmp_path):
    # The Dolor cluster leaves sanitizer output in stderr.log rather than merging
    # it into server.log, so each node is judged by its server+stderr pair.
    log = _server_log(tmp_path, "server0.log", "2026.01.01 Application: started\n")
    stderr = _server_log(tmp_path, "stderr0.log", _OOM_LINE)
    is_oom_success, messages = _classify_sanitizer_oom(
        [log], [stderr], server_died=True, server_exit_code=0, workspace_path=tmp_path
    )
    assert is_oom_success is True
    assert any("Sanitizer OOM on server 0" in m for m in messages)


def test_crash_only_in_stderr_blocks_oom_downgrade(tmp_path):
    # A genuine crash sitting in stderr.log must veto the OOM-is-success path
    # even when server.log itself only shows the OOM.
    log = _server_log(tmp_path, "server0.log", _OOM_LINE)
    stderr = _server_log(tmp_path, "stderr0.log", _TSAN_CRASH)
    is_oom_success, _ = _classify_sanitizer_oom(
        [log], [stderr], server_died=True, server_exit_code=0, workspace_path=tmp_path
    )
    assert is_oom_success is False


def test_collapse_server_exit_code_prefers_sigkill():
    # A node killed by the kernel OOM killer must surface as 137 so that
    # `_classify_sanitizer_oom` can apply its "SIGKILL with no sanitizer report" path,
    # even when another node exited cleanly first.
    assert collapse_server_exit_code([0, 137]) == 137
    assert collapse_server_exit_code([-9]) == 137


def test_collapse_server_exit_code_ignores_graceful_exits():
    # 0 / SIGTERM are the normal outcomes of the shutdowns Dolor performs itself.
    assert collapse_server_exit_code([]) == 0
    assert collapse_server_exit_code([0, 0, 0]) == 0
    assert collapse_server_exit_code([0, -15, 143]) == 0


def test_collapse_server_exit_code_reports_abnormal_exit():
    assert collapse_server_exit_code([0, 134]) == 134
    assert collapse_server_exit_code([139, 134]) == 139

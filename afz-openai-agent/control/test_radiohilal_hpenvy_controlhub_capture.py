import base64
import hashlib
import json
import os
import pathlib
import re
import subprocess
import tempfile
import unittest
import zipfile
from types import SimpleNamespace
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent
REPO = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = REPO / ".github/workflows/radiohilal-hpenvy-controlhub-readonly-capture.yml"

import sys
sys.path.insert(0, str(ROOT))

import radiohilal_hpenvy_controlhub_capture as cap


EXPECTED_TRIGGER_PATHS = {
    ".github/workflows/radiohilal-hpenvy-controlhub-readonly-capture.yml",
    ".github/afz-radiohilal-controlhub-capture-signal.txt",
    "afz-openai-agent/control/radiohilal_hpenvy_controlhub_capture.py",
    "afz-openai-agent/control/test_radiohilal_hpenvy_controlhub_capture.py",
}
EXPECTED_UPLOAD_PATHS = {
    "${{ runner.temp }}/radiohilal-controlhub-capture/" + name
    for name in cap.OUTPUT_NAMES
}
KNOWN_HOST = (
    "100.71.26.69 ssh-ed25519 "
    "AAAAC3NzaC1lZDI1NTE5AAAAIMOCKMOCKMOCKMOCKMOCKMOCKMOCKMOCK12\n"
).encode("utf-8")


def validate_workflow_text(text: str) -> None:
    lines = text.splitlines()
    top_keys = []
    for line in lines:
        if line and not line.startswith(" ") and ":" in line:
            top_keys.append(line.split(":", 1)[0])
    if top_keys != ["name", "on", "permissions", "concurrency", "jobs"]:
        raise ValueError(f"top-level workflow structure invalid: {top_keys}")

    forbidden_security_keys = (
        "continue-on-error:",
        "env:",
        "environment:",
        "container:",
        "services:",
        "defaults:",
        "working-directory:",
        "ref:",
    )
    for line in lines:
        stripped = line.strip()
        if any(stripped.startswith(key) for key in forbidden_security_keys):
            raise ValueError(f"security-sensitive workflow override forbidden: {stripped}")
        if stripped.startswith("shell:") and stripped != "shell: bash":
            raise ValueError(f"workflow shell override invalid: {stripped}")

    on_index = lines.index("on:")
    permission_index = lines.index("permissions:")
    on_lines = lines[on_index + 1 : permission_index]
    triggers = [
        line.strip()[:-1]
        for line in on_lines
        if line.startswith("  ")
        and not line.startswith("    ")
        and line.strip().endswith(":")
    ]
    if triggers != ["workflow_dispatch", "pull_request"]:
        raise ValueError(f"workflow triggers invalid: {triggers}")
    if any(line.strip().startswith("push:") for line in on_lines):
        raise ValueError("push trigger forbidden")

    paths: set[str] = set()
    in_paths = False
    for line in on_lines:
        stripped = line.strip()
        if stripped == "paths:":
            in_paths = True
            continue
        if in_paths and stripped.startswith("- "):
            paths.add(stripped[2:].strip("'\""))
        elif in_paths and stripped and not line.startswith("      "):
            in_paths = False
    if paths != EXPECTED_TRIGGER_PATHS:
        raise ValueError(f"pull_request paths invalid: {paths}")

    concurrency_index = lines.index("concurrency:")
    root_permissions = [
        line.strip()
        for line in lines[permission_index + 1 : concurrency_index]
        if line.strip()
    ]
    if root_permissions != ["contents: read"]:
        raise ValueError(f"root permissions invalid: {root_permissions}")

    jobs_index = lines.index("jobs:")
    job_names = [
        re.fullmatch(r"  ([A-Za-z0-9_-]+):", line).group(1)
        for line in lines[jobs_index + 1 :]
        if re.fullmatch(r"  ([A-Za-z0-9_-]+):", line)
    ]
    if job_names != ["validate-readonly-boundary", "capture"]:
        raise ValueError(f"job set invalid: {job_names}")


    validate_start = lines.index("  validate-readonly-boundary:")
    capture_start = lines.index("  capture:")
    validate_lines = lines[validate_start:capture_start]
    capture_lines = lines[capture_start:]

    validate_text = "\n".join(validate_lines)
    validate_steps_index = validate_lines.index("    steps:")
    validate_header_block = [
        line for line in validate_lines[: validate_steps_index + 1]
        if line.strip()
    ]
    if validate_header_block != [
        "  validate-readonly-boundary:",
        "    runs-on: ubuntu-latest",
        "    timeout-minutes: 2",
        "    steps:",
    ]:
        raise ValueError(
            f"validation job header invalid: {validate_header_block}"
        )
    if "permissions:" in validate_text:
        raise ValueError("validation job permission override forbidden")
    required_validation = (
        "    runs-on: ubuntu-latest",
        "    timeout-minutes: 2",
        "          persist-credentials: false",
        "          python3 -m py_compile "
        "afz-openai-agent/control/radiohilal_hpenvy_controlhub_capture.py "
        "afz-openai-agent/control/test_radiohilal_hpenvy_controlhub_capture.py",
        "          python3 afz-openai-agent/control/"
        "test_radiohilal_hpenvy_controlhub_capture.py -v",
    )
    for token in required_validation:
        if validate_text.count(token) != 1:
            raise ValueError(f"validation contract invalid: {token}")
    validate_step_headers = [
        line.strip()
        for line in validate_lines
        if re.fullmatch(r"      - [A-Za-z0-9_-]+:.*", line)
    ]
    if validate_step_headers != [
        "- uses: actions/checkout@v4",
        "- name: Validate capture implementation",
    ]:
        raise ValueError(
            f"validation step structure invalid: {validate_step_headers}"
        )
    validate_checkout_start = validate_lines.index("      - uses: actions/checkout@v4")
    validate_test_start = validate_lines.index(
        "      - name: Validate capture implementation"
    )
    validate_checkout_block = [
        line for line in validate_lines[validate_checkout_start:validate_test_start]
        if line.strip()
    ]
    if validate_checkout_block != [
        "      - uses: actions/checkout@v4",
        "        with:",
        "          persist-credentials: false",
    ]:
        raise ValueError(
            f"validation checkout block invalid: {validate_checkout_block}"
        )
    validate_test_block = [
        line for line in validate_lines[validate_test_start:]
        if line.strip()
    ]
    if validate_test_block != [
        "      - name: Validate capture implementation",
        "        shell: bash",
        "        run: |",
        "          set -euo pipefail",
        "          python3 -m py_compile afz-openai-agent/control/radiohilal_hpenvy_controlhub_capture.py afz-openai-agent/control/test_radiohilal_hpenvy_controlhub_capture.py",
        "          python3 afz-openai-agent/control/test_radiohilal_hpenvy_controlhub_capture.py -v",
    ]:
        raise ValueError(
            f"validation test block invalid: {validate_test_block}"
        )
    if any(
        line.strip().startswith("if:")
        for line in validate_lines
        if line.startswith("        ")
    ):
        raise ValueError("validation step-level if forbidden")

    validate_run_index = validate_lines.index("        run: |")
    validate_run_lines = []
    for line in validate_lines[validate_run_index + 1 :]:
        if line and not line.startswith("          "):
            break
        if line.strip():
            validate_run_lines.append(line.strip())
    if validate_run_lines != [
        "set -euo pipefail",
        "python3 -m py_compile "
        "afz-openai-agent/control/radiohilal_hpenvy_controlhub_capture.py "
        "afz-openai-agent/control/test_radiohilal_hpenvy_controlhub_capture.py",
        "python3 afz-openai-agent/control/"
        "test_radiohilal_hpenvy_controlhub_capture.py -v",
    ]:
        raise ValueError(
            f"validation run block invalid: {validate_run_lines}"
        )

    capture_text = "\n".join(capture_lines)
    capture_header_end = capture_lines.index("    steps:")
    capture_header = capture_lines[:capture_header_end]
    capture_header_block = [
        line for line in capture_lines[: capture_header_end + 1]
        if line.strip()
    ]
    if capture_header_block != [
        "  capture:",
        "    needs: validate-readonly-boundary",
        "    if: github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main'",
        "    permissions:",
        "      contents: read",
        "      id-token: write",
        "    runs-on: ubuntu-latest",
        "    timeout-minutes: 5",
        "    steps:",
    ]:
        raise ValueError(
            f"capture job header invalid: {capture_header_block}"
        )
    if "    needs: validate-readonly-boundary" not in capture_header:
        raise ValueError("capture dependency missing")
    condition_lines = [
        line.strip()
        for line in capture_header
        if line.strip().startswith("if:")
    ]
    if condition_lines != [
        "if: github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main'"
    ]:
        raise ValueError(f"capture condition invalid: {condition_lines}")

    perm_start = capture_header.index("    permissions:")
    run_index = capture_header.index("    runs-on: ubuntu-latest")
    capture_permissions = [
        line.strip()
        for line in capture_header[perm_start + 1 : run_index]
        if line.strip()
    ]
    if capture_permissions != ["contents: read", "id-token: write"]:
        raise ValueError(f"capture permissions invalid: {capture_permissions}")
    if capture_header.count("    timeout-minutes: 5") != 1:
        raise ValueError("capture timeout invalid")

    capture_step_headers = [
        line.strip()
        for line in capture_lines
        if re.fullmatch(r"      - [A-Za-z0-9_-]+:.*", line)
    ]
    if capture_step_headers != [
        "- uses: actions/checkout@v4",
        "- name: Join AFZ tailnet",
        "- name: Capture exact validated Control Hub source",
        "- name: Upload validated read-only capture",
    ]:
        raise ValueError(
            f"capture step structure invalid: {capture_step_headers}"
        )

    capture_checkout_start = capture_lines.index("      - uses: actions/checkout@v4")
    tailscale_start = capture_lines.index("      - name: Join AFZ tailnet")
    capture_step_start = capture_lines.index(
        "      - name: Capture exact validated Control Hub source"
    )
    upload_start = capture_lines.index(
        "      - name: Upload validated read-only capture"
    )
    capture_checkout_block = [
        line for line in capture_lines[capture_checkout_start:tailscale_start]
        if line.strip()
    ]
    if capture_checkout_block != [
        "      - uses: actions/checkout@v4",
        "        with:",
        "          persist-credentials: false",
    ]:
        raise ValueError(
            f"capture checkout block invalid: {capture_checkout_block}"
        )
    tailscale_block = [
        line for line in capture_lines[tailscale_start:capture_step_start]
        if line.strip()
    ]
    if tailscale_block != [
        "      - name: Join AFZ tailnet",
        "        uses: tailscale/github-action@v4",
        "        with:",
        "          oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}",
        "          audience: ${{ secrets.TS_AUDIENCE }}",
        "          tags: tag:afz-deploy",
    ]:
        raise ValueError(f"Tailscale block invalid: {tailscale_block}")
    capture_command_block = [
        line for line in capture_lines[capture_step_start:upload_start]
        if line.strip()
    ]
    if capture_command_block != [
        "      - name: Capture exact validated Control Hub source",
        "        shell: bash",
        "        run: |",
        "          set -euo pipefail",
        "          python3 afz-openai-agent/control/radiohilal_hpenvy_controlhub_capture.py \\",
        '            --output "${RUNNER_TEMP}/radiohilal-controlhub-capture"',
    ]:
        raise ValueError(
            f"capture command block invalid: {capture_command_block}"
        )
    if any(
        line.strip().startswith("if:")
        for line in capture_lines[capture_header_end + 1 :]
        if line.startswith("        ")
    ):
        raise ValueError("capture step-level if forbidden")

    capture_uses: list[str] = []
    for line in capture_lines:
        stripped = line.strip()
        if stripped.startswith("- uses: "):
            capture_uses.append(stripped[len("- uses: ") :])
        elif stripped.startswith("uses: "):
            capture_uses.append(stripped[len("uses: ") :])
    if capture_uses != [
        "actions/checkout@v4",
        "tailscale/github-action@v4",
        "actions/upload-artifact@v4",
    ]:
        raise ValueError(f"capture action set invalid: {capture_uses}")

    capture_run_index = capture_lines.index("        run: |")
    capture_run_lines = []
    for line in capture_lines[capture_run_index + 1 :]:
        if line and not line.startswith("          "):
            break
        if line.strip():
            capture_run_lines.append(line.strip())
    if capture_run_lines != [
        "set -euo pipefail",
        "python3 afz-openai-agent/control/"
        "radiohilal_hpenvy_controlhub_capture.py \\",
        '--output "${RUNNER_TEMP}/radiohilal-controlhub-capture"',
    ]:
        raise ValueError(f"capture run block invalid: {capture_run_lines}")

    if capture_text.count("persist-credentials: false") != 1:
        raise ValueError("capture checkout credential setting invalid")
    if capture_text.count("tailscale/github-action@v4") != 1:
        raise ValueError("Tailscale action count invalid")
    if capture_text.count("radiohilal_hpenvy_controlhub_capture.py") != 1:
        raise ValueError("capture client invocation count invalid")
    if "tailscale ssh" in capture_text:
        raise ValueError("workflow must not embed remote SSH command")
    if "curl " in capture_text:
        raise ValueError("workflow must not add HTTP transport")

    output_line = '--output "${RUNNER_TEMP}/radiohilal-controlhub-capture"'
    if capture_text.count(output_line) != 1:
        raise ValueError("capture output path invalid")

    upload_index = capture_lines.index("      - name: Upload validated read-only capture")
    upload_lines = capture_lines[upload_index:]
    path_index = upload_lines.index("          path: |")
    upload_paths: list[str] = []
    for line in upload_lines[path_index + 1 :]:
        if line.startswith("            "):
            upload_paths.append(line.strip())
            continue
        break
    expected_upload_paths = [
        "${{ runner.temp }}/radiohilal-controlhub-capture/" + name
        for name in cap.OUTPUT_NAMES
    ]
    if upload_paths != expected_upload_paths:
        raise ValueError(f"upload path order invalid: {upload_paths}")
    upload_block = [line for line in upload_lines if line.strip()]
    expected_upload_block = [
        "      - name: Upload validated read-only capture",
        "        uses: actions/upload-artifact@v4",
        "        with:",
        "          name: radiohilal-hpenvy-controlhub-readonly-capture",
        "          path: |",
        *["            " + path for path in expected_upload_paths],
        "          if-no-files-found: error",
        "          retention-days: 7",
    ]
    if upload_block != expected_upload_block:
        raise ValueError(f"upload block invalid: {upload_block}")
    if capture_text.count("actions/upload-artifact@v4") != 1:
        raise ValueError("upload action count invalid")


class SecretScanTests(unittest.TestCase):
    def scan_ok(self, source: str) -> None:
        cap.scan_python_source(source.encode("utf-8"))

    def scan_reject(self, source: str) -> None:
        with self.assertRaises(cap.CaptureError):
            cap.scan_python_source(source.encode("utf-8"))

    def test_safe_environment_lookup_passes(self):
        self.scan_ok(
            "import os\n"
            "TOKEN = os.getenv('AFZ_HUB_TOKEN')\n"
            "PASSWORD = os.environ.get('PASSWORD', '')\n"
        )

    def test_direct_literal_secret_rejected(self):
        self.scan_reject("AFZ_HUB_TOKEN = 'ordinary-value'\n")

    def test_short_password_rejected(self):
        self.scan_reject("password = 'x'\n")

    def test_bytes_secret_rejected(self):
        self.scan_reject("AFZ_HUB_TOKEN = b'ordinary-value'\n")

    def test_annotated_secret_rejected(self):
        self.scan_reject("AFZ_HUB_TOKEN: str = 'ordinary-value'\n")

    def test_concatenated_secret_rejected(self):
        self.scan_reject("AFZ_HUB_TOKEN = 'ordinary-' + 'value'\n")

    def test_adjacent_literal_secret_rejected(self):
        self.scan_reject("AFZ_HUB_TOKEN = 'ordinary-' 'value'\n")

    def test_alias_secret_rejected(self):
        self.scan_reject(
            "ALIAS = 'ordinary-value'\n"
            "AFZ_HUB_TOKEN = ALIAS\n"
        )

    def test_chained_alias_secret_rejected(self):
        self.scan_reject(
            "A = 'ordinary-value'\n"
            "B = A\n"
            "AFZ_HUB_TOKEN = B\n"
        )

    def test_os_environ_dict_secret_rejected(self):
        self.scan_reject(
            "import os\n"
            "os.environ = {'AFZ_HUB_TOKEN': 'ordinary-value'}\n"
        )

    def test_tuple_destructuring_secret_rejected(self):
        self.scan_reject(
            "AFZ_HUB_TOKEN, mode = ('ordinary-value', 'production')\n"
        )

    def test_list_destructuring_secret_rejected(self):
        self.scan_reject(
            "[AFZ_HUB_TOKEN, mode] = ['ordinary-value', 'production']\n"
        )

    def test_subscript_secret_rejected(self):
        self.scan_reject(
            "cfg = {}\n"
            "cfg['AFZ_HUB_TOKEN'] = 'ordinary-value'\n"
        )

    def test_dict_secret_rejected(self):
        self.scan_reject("cfg = {'client_secret': 'ordinary-value'}\n")

    def test_env_default_secret_rejected(self):
        self.scan_reject(
            "import os\n"
            "AFZ_HUB_TOKEN = os.getenv('AFZ_HUB_TOKEN', 'ordinary-value')\n"
        )

    def test_env_default_concatenation_rejected(self):
        self.scan_reject(
            "import os\n"
            "AFZ_HUB_TOKEN = os.getenv('AFZ_HUB_TOKEN', 'ordinary-' + 'value')\n"
        )

    def test_env_default_wrapped_expression_rejected(self):
        self.scan_reject(
            "import os\n"
            "value = os.getenv('PASSWORD', str('ordinary-value'))\n"
        )

    def test_env_default_keyword_unpacking_rejected(self):
        self.scan_reject(
            "import os\n"
            "TOKEN = os.getenv('TOKEN', **{'default': 'ordinary-value'})\n"
        )

    def test_keyword_only_env_default_wrapped_expression_rejected(self):
        self.scan_reject(
            "import os\n"
            "value = os.getenv(key='PASSWORD', default=str('ordinary-value'))\n"
        )

    def test_keyword_unpacking_env_call_rejected(self):
        self.scan_reject(
            "import os\n"
            "value = os.getenv(**{'key': 'PASSWORD', 'default': 'ordinary-value'})\n"
        )

    def test_keyword_only_sensitive_env_empty_default_passes(self):
        self.scan_ok(
            "import os\n"
            "password = os.getenv(key='PASSWORD', default='')\n"
        )

    def test_augassign_invalidates_empty_alias(self):
        self.scan_reject(
            "value = ''\n"
            "value += 'ordinary-value'\n"
            "password = value\n"
        )

    def test_if_branch_cannot_overwrite_runtime_constant_state(self):
        self.scan_reject(
            "value = 'ordinary-value'\n"
            "if False:\n"
            "    value = ''\n"
            "password = value\n"
        )

    def test_dict_constructor_pair_secret_rejected(self):
        self.scan_reject(
            "cfg = dict([('password', 'ordinary-value')])\n"
        )

    def test_sensitive_loop_target_rejected(self):
        self.scan_reject(
            "for password in ['ordinary-value']:\n"
            "    pass\n"
        )

    def test_or_fallback_secret_rejected(self):
        self.scan_reject(
            "import os\n"
            "AFZ_HUB_TOKEN = os.getenv('AFZ_HUB_TOKEN') or 'ordinary-value'\n"
        )

    def test_conditional_secret_rejected(self):
        self.scan_reject(
            "AFZ_HUB_TOKEN = 'ordinary-value' if enabled else ''\n"
        )

    def test_lambda_default_secret_rejected(self):
        self.scan_reject(
            "f = lambda password='ordinary-value': password\n"
        )

    def test_folded_generic_token_rejected(self):
        self.scan_reject(
            "x = 'ghp_' + 'ABCDEFGHIJKLMNOPQRSTUVWXYZ12'\n"
        )

    def test_adjacent_folded_generic_token_rejected(self):
        self.scan_reject(
            "x = 'ghp_' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ12'\n"
        )

    def test_function_default_secret_rejected(self):
        self.scan_reject("def f(password='ordinary-value'):\n    return password\n")

    def test_function_default_nested_dict_secret_rejected(self):
        self.scan_reject(
            "def f(cfg={'password': 'ordinary-value'}):\n"
            "    return cfg\n"
        )

    def test_lambda_default_nested_dict_secret_rejected(self):
        self.scan_reject(
            "f = lambda cfg={'client_secret': 'ordinary-value'}: cfg\n"
        )

    def test_unsupported_sensitive_call_expression_rejected(self):
        self.scan_reject("password = str('ordinary-value')\n")

    def test_unsupported_sensitive_runtime_expression_rejected(self):
        self.scan_reject("password = load_runtime_value()\n")

    def test_sensitive_os_environ_subscript_passes(self):
        self.scan_ok(
            "import os\n"
            "password = os.environ['PASSWORD']\n"
        )

    def test_sensitive_os_getenv_or_empty_passes(self):
        self.scan_ok(
            "import os\n"
            "token = os.getenv('AFZ_HUB_TOKEN') or ''\n"
        )

    def test_keyword_secret_rejected(self):
        self.scan_reject("configure(password='ordinary-value')\n")

    def test_setattr_secret_rejected(self):
        self.scan_reject("setattr(config, 'AFZ_HUB_TOKEN', 'ordinary-value')\n")

    def test_generic_token_prefix_rejected(self):
        self.scan_reject("x = 'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ12'\n")

    def test_private_key_rejected(self):
        self.scan_reject("x = '''-----BEGIN PRIVATE KEY-----\nabc\n'''\n")

    def test_credential_url_rejected(self):
        self.scan_reject("x = 'postgres://user:password@db.example/db'\n")

    def test_jwt_rejected(self):
        self.scan_reject(
            "x = 'eyJabcdefghijk.abcdefghijk.abcdefghijk'\n"
        )

    def test_invalid_python_rejected(self):
        self.scan_reject("def broken(:\n")


class SftpTransportPureTests(unittest.TestCase):
    def test_hostkey_probe_batch_is_read_only(self):
        batch = cap.build_hostkey_probe_batch()
        commands = [
            line.lstrip("@").split(None, 1)[0]
            for line in batch.splitlines()
            if line.strip()
        ]
        self.assertEqual(commands, ["pwd", "quit"])
        for forbidden in ("get", "put", "rm", "rename", "mkdir", "chmod", "chown", "ln"):
            self.assertNotRegex(batch, rf"(?m)^@?{forbidden}\b")

    def test_source_fetch_batch_is_read_only_and_exact(self):
        batch = cap.build_source_fetch_batch()
        self.assertEqual(
            batch,
            f"get {cap.REMOTE_PATH} source.py\nquit\n",
        )
        commands = [
            line.lstrip("@").split(None, 1)[0]
            for line in batch.splitlines()
            if line.strip()
        ]
        self.assertEqual(commands, ["get", "quit"])
        for forbidden in ("put", "rm", "rename", "mkdir", "chmod", "chown", "ln"):
            self.assertNotRegex(batch, rf"(?m)^@?{forbidden}\b")

    def test_known_hosts_filter_accepts_only_target(self):
        text = (
            KNOWN_HOST.decode()
            + "100.1.2.3 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOTHEROTHEROTHEROTHEROTHER12\n"
        )
        self.assertEqual(cap.filter_target_known_hosts(text), KNOWN_HOST)

    def test_known_hosts_filter_rejects_missing_target(self):
        with self.assertRaisesRegex(cap.CaptureError, "host key missing"):
            cap.filter_target_known_hosts(
                "100.1.2.3 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOTHEROTHEROTHEROTHEROTHER12\n"
            )

    def test_known_hosts_filter_rejects_duplicate_target(self):
        with self.assertRaisesRegex(cap.CaptureError, "duplicate"):
            cap.filter_target_known_hosts((KNOWN_HOST * 2).decode())

    def test_sftp_args_are_fixed_and_no_shell_command(self):
        args = cap._sftp_args(
            sftp="/usr/bin/sftp",
            tailscale="/usr/bin/tailscale",
            batch=pathlib.Path("/tmp/batch"),
            known_hosts=pathlib.Path("/tmp/known_hosts"),
            strict_host_key="yes",
        )
        self.assertEqual(args[0], "/usr/bin/sftp")
        self.assertEqual(args[-1], cap.TARGET)
        self.assertIn("StrictHostKeyChecking=yes", args)
        self.assertIn("ProxyCommand=/usr/bin/tailscale nc %h %p", args)
        self.assertNotIn("ssh", pathlib.Path(args[0]).name)
        joined = " ".join(args)
        for forbidden in ("bash -c", "python -c", "exec ", "sudo ", "systemctl", "docker "):
            self.assertNotIn(forbidden, joined)

    def test_invalid_hostkey_mode_rejected(self):
        with self.assertRaisesRegex(cap.CaptureError, "host-key mode"):
            cap._sftp_args(
                sftp="/usr/bin/sftp",
                tailscale="/usr/bin/tailscale",
                batch=pathlib.Path("/tmp/batch"),
                known_hosts=pathlib.Path("/tmp/known_hosts"),
                strict_host_key="no",
            )


@unittest.skipUnless(os.name == "posix", "POSIX subprocess/resource test")
class SftpTransportPosixTests(unittest.TestCase):
    @mock.patch.object(cap.subprocess, "run")
    @mock.patch.object(cap.shutil, "which")
    def test_hostkey_probe_uses_only_sftp_subsystem(self, which, run):
        which.side_effect = lambda name: {
            "sftp": "/usr/bin/sftp",
            "tailscale": "/usr/bin/tailscale",
        }[name]

        def fake_run(args, **kwargs):
            stage = pathlib.Path(kwargs["cwd"])
            known = pathlib.Path(
                next(
                    x.split("=", 1)[1]
                    for x in args
                    if x.startswith("UserKnownHostsFile=")
                )
            )
            known.write_bytes(KNOWN_HOST)
            self.assertNotIn("shell", kwargs)
            self.assertIs(kwargs["stdin"], subprocess.DEVNULL)
            self.assertIs(kwargs["stdout"], subprocess.DEVNULL)
            self.assertIs(kwargs["stderr"], subprocess.DEVNULL)
            self.assertTrue(callable(kwargs["preexec_fn"]))
            self.assertEqual(args[0], "/usr/bin/sftp")
            self.assertIn("StrictHostKeyChecking=accept-new", args)
            self.assertIn("GlobalKnownHostsFile=/dev/null", args)
            self.assertIn("SendEnv=-*", args)
            self.assertIn("ProxyCommand=/usr/bin/tailscale nc %h %p", args)
            self.assertEqual(args[-1], cap.TARGET)
            batch = pathlib.Path(args[args.index("-b") + 1]).read_text()
            self.assertEqual(batch, cap.build_hostkey_probe_batch())
            self.assertEqual(stage.name.startswith("radiohilal-hostkey-probe-"), True)
            return SimpleNamespace(returncode=0)

        run.side_effect = fake_run
        with tempfile.TemporaryDirectory() as td:
            known = cap.establish_pinned_host_key_via_sftp(pathlib.Path(td))
        self.assertEqual(known, KNOWN_HOST)
        which.assert_any_call("sftp")
        which.assert_any_call("tailscale")

    @mock.patch.object(cap.subprocess, "run")
    @mock.patch.object(cap.shutil, "which")
    def test_source_fetch_uses_pinned_sftp_only(self, which, run):
        which.side_effect = lambda name: {
            "sftp": "/usr/bin/sftp",
            "tailscale": "/usr/bin/tailscale",
        }[name]
        payload = b"print('safe')\n"

        def fake_run(args, **kwargs):
            stage = pathlib.Path(kwargs["cwd"])
            (stage / "source.py").write_bytes(payload)
            self.assertNotIn("shell", kwargs)
            self.assertIs(kwargs["stdin"], subprocess.DEVNULL)
            self.assertIs(kwargs["stdout"], subprocess.DEVNULL)
            self.assertIs(kwargs["stderr"], subprocess.DEVNULL)
            self.assertTrue(callable(kwargs["preexec_fn"]))
            self.assertEqual(args[0], "/usr/bin/sftp")
            self.assertIn("StrictHostKeyChecking=yes", args)
            self.assertIn("GlobalKnownHostsFile=/dev/null", args)
            self.assertIn("ProxyCommand=/usr/bin/tailscale nc %h %p", args)
            self.assertEqual(args[-1], cap.TARGET)
            user_known = pathlib.Path(
                next(
                    x.split("=", 1)[1]
                    for x in args
                    if x.startswith("UserKnownHostsFile=")
                )
            )
            self.assertEqual(user_known.read_bytes(), KNOWN_HOST)
            batch = pathlib.Path(args[args.index("-b") + 1]).read_text()
            self.assertEqual(batch, cap.build_source_fetch_batch())
            return SimpleNamespace(returncode=0)

        run.side_effect = fake_run
        with tempfile.TemporaryDirectory() as td:
            result = cap.fetch_source_via_pinned_sftp(
                pathlib.Path(td), KNOWN_HOST
            )
        self.assertEqual(result, payload)

    @mock.patch.object(cap.subprocess, "run")
    @mock.patch.object(cap.shutil, "which")
    def test_source_fetch_never_exposes_remote_stderr(self, which, run):
        which.side_effect = lambda name: {
            "sftp": "/usr/bin/sftp",
            "tailscale": "/usr/bin/tailscale",
        }[name]
        run.return_value = SimpleNamespace(returncode=7)
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaisesRegex(cap.CaptureError, "exit 7"):
                cap.fetch_source_via_pinned_sftp(
                    pathlib.Path(td), KNOWN_HOST
                )
        _, kwargs = run.call_args
        self.assertIs(kwargs["stderr"], subprocess.DEVNULL)

    def test_source_fetch_rejects_duplicate_known_hosts(self):
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaisesRegex(cap.CaptureError, "duplicate"):
                cap.fetch_source_via_pinned_sftp(
                    pathlib.Path(td), KNOWN_HOST + KNOWN_HOST
                )


class OutputTests(unittest.TestCase):
    def test_output_requires_direct_runner_temp_child(self):
        with tempfile.TemporaryDirectory() as td:
            runner = pathlib.Path(td)
            nested = runner / "nested"
            nested.mkdir()
            with self.assertRaisesRegex(cap.CaptureError, "direct child"):
                cap.emit_outputs(
                    nested / "radiohilal-controlhub-capture",
                    runner,
                    b"x = 1\n",
                )

    def test_existing_output_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            runner = pathlib.Path(td)
            out = runner / "radiohilal-controlhub-capture"
            out.mkdir()
            with self.assertRaisesRegex(cap.CaptureError, "already exists"):
                cap.emit_outputs(out, runner, b"x = 1\n")

    def test_deterministic_zip_has_only_main_py(self):
        source = b"x = 1\n"
        with tempfile.TemporaryDirectory() as td1, tempfile.TemporaryDirectory() as td2:
            runner1 = pathlib.Path(td1)
            runner2 = pathlib.Path(td2)
            out1 = runner1 / "radiohilal-controlhub-capture"
            out2 = runner2 / "radiohilal-controlhub-capture"
            cap.emit_outputs(out1, runner1, source)
            cap.emit_outputs(out2, runner2, source)

            self.assertEqual({p.name for p in out1.iterdir()}, set(cap.OUTPUT_NAMES))
            with zipfile.ZipFile(out1 / "controlhub-source.zip") as zf:
                self.assertEqual(zf.namelist(), [cap.REMOTE_PATH.lstrip("/")])
                info = zf.infolist()[0]
                self.assertEqual(info.date_time, (1980, 1, 1, 0, 0, 0))
                self.assertFalse(info.is_dir())
                self.assertEqual(zf.read(info.filename), source)

            self.assertEqual(
                hashlib.sha256(
                    (out1 / "controlhub-source.zip").read_bytes()
                ).hexdigest(),
                hashlib.sha256(
                    (out2 / "controlhub-source.zip").read_bytes()
                ).hexdigest(),
            )
            manifest = json.loads(
                (out1 / "controlhub-manifest.json").read_text(encoding="utf-8")
            )
            self.assertEqual(
                manifest["transport"],
                "tailscale-sftp-hostkey-probe-plus-pinned-sftp-source-read",
            )
            self.assertEqual(manifest["remote_path"], cap.REMOTE_PATH)
            self.assertFalse(manifest["secret_values_emitted"])
            self.assertFalse(manifest["remote_mutation_performed"])

    def test_capture_binds_to_runner_temp_and_scans_before_output(self):
        with tempfile.TemporaryDirectory() as td:
            runner = pathlib.Path(td)
            out = runner / "radiohilal-controlhub-capture"
            with mock.patch.dict(os.environ, {"RUNNER_TEMP": str(runner)}, clear=False):
                with mock.patch.object(
                    cap,
                    "establish_pinned_host_key_via_sftp",
                    return_value=KNOWN_HOST,
                ):
                    with mock.patch.object(
                        cap,
                        "fetch_source_via_pinned_sftp",
                        return_value=b"AFZ_HUB_TOKEN = 'hardcoded'\n",
                    ):
                        with self.assertRaises(cap.CaptureError):
                            cap.capture(out)
            self.assertFalse(out.exists())


class WorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")

    def assert_rejected(self, text: str):
        with self.assertRaises(ValueError):
            validate_workflow_text(text)

    def test_current_workflow_contract(self):
        validate_workflow_text(self.text)

    def test_add_push_trigger_rejected(self):
        weakened = self.text.replace(
            "on:\n  workflow_dispatch:",
            "on:\n  push:\n  workflow_dispatch:",
            1,
        )
        self.assert_rejected(weakened)

    def test_add_root_oidc_permission_rejected(self):
        weakened = self.text.replace(
            "permissions:\n  contents: read",
            "permissions:\n  contents: read\n  id-token: write",
            1,
        )
        self.assert_rejected(weakened)

    def test_add_extra_job_rejected(self):
        weakened = self.text + "\n  extra-job:\n    runs-on: ubuntu-latest\n"
        self.assert_rejected(weakened)

    def test_remove_dependency_rejected(self):
        weakened = self.text.replace(
            "    needs: validate-readonly-boundary\n",
            "",
            1,
        )
        self.assert_rejected(weakened)

    def test_additive_capture_condition_rejected(self):
        weakened = self.text.replace(
            "if: github.event_name == 'workflow_dispatch'",
            "if: github.event_name == 'workflow_dispatch' || "
            "github.event_name == 'pull_request'",
            1,
        )
        self.assert_rejected(weakened)

    def test_capture_if_true_rejected(self):
        weakened = self.text.replace(
            "if: github.event_name == 'workflow_dispatch' && "
            "github.ref == 'refs/heads/main'",
            "if: true",
            1,
        )
        self.assertNotEqual(weakened, self.text)
        self.assert_rejected(weakened)

    def test_capture_main_ref_required(self):
        weakened = self.text.replace(
            "if: github.event_name == 'workflow_dispatch' && "
            "github.ref == 'refs/heads/main'",
            "if: github.event_name == 'workflow_dispatch'",
            1,
        )
        self.assertNotEqual(weakened, self.text)
        self.assert_rejected(weakened)

    def test_validation_permission_override_rejected(self):
        weakened = self.text.replace(
            "    timeout-minutes: 2\n    steps:",
            "    timeout-minutes: 2\n    permissions:\n      id-token: write\n"
            "    steps:",
            1,
        )
        self.assert_rejected(weakened)

    def test_continue_on_error_rejected(self):
        weakened = self.text.replace(
            "      - name: Validate capture implementation\n"
            "        shell: bash",
            "      - name: Validate capture implementation\n"
            "        continue-on-error: true\n"
            "        shell: bash",
            1,
        )
        self.assert_rejected(weakened)

    def test_quoted_continue_on_error_rejected(self):
        weakened = self.text.replace(
            "      - name: Validate capture implementation\n"
            "        shell: bash",
            "      - name: Validate capture implementation\n"
            '        "continue-on-error": true\n'
            "        shell: bash",
            1,
        )
        self.assertNotEqual(weakened, self.text)
        self.assert_rejected(weakened)

    def test_job_level_quoted_continue_on_error_rejected(self):
        weakened = self.text.replace(
            "    timeout-minutes: 2\n"
            "    steps:",
            "    timeout-minutes: 2\n"
            '    "continue-on-error": true\n'
            "    steps:",
            1,
        )
        self.assertNotEqual(weakened, self.text)
        self.assert_rejected(weakened)

    def test_capture_job_level_quoted_env_rejected(self):
        weakened = self.text.replace(
            "    timeout-minutes: 5\n"
            "    steps:",
            "    timeout-minutes: 5\n"
            '    "env":\n'
            "      BASH_ENV: /tmp/hook\n"
            "    steps:",
            1,
        )
        self.assertNotEqual(weakened, self.text)
        self.assert_rejected(weakened)

    def test_capture_checkout_ref_override_rejected(self):
        weakened = self.text.replace(
            "      - uses: actions/checkout@v4\n"
            "        with:\n"
            "          persist-credentials: false\n\n"
            "      - name: Join AFZ tailnet",
            "      - uses: actions/checkout@v4\n"
            "        with:\n"
            "          persist-credentials: false\n"
            "          ref: main\n\n"
            "      - name: Join AFZ tailnet",
            1,
        )
        self.assert_rejected(weakened)

    def test_tailscale_tag_change_rejected(self):
        weakened = self.text.replace(
            "          tags: tag:afz-deploy",
            "          tags: tag:unexpected",
            1,
        )
        self.assert_rejected(weakened)

    def test_tailscale_extra_input_rejected(self):
        weakened = self.text.replace(
            "          tags: tag:afz-deploy",
            "          tags: tag:afz-deploy\n"
            "          hostname: unexpected",
            1,
        )
        self.assert_rejected(weakened)

    def test_step_env_override_rejected(self):
        weakened = self.text.replace(
            "      - name: Capture exact validated Control Hub source\n"
            "        shell: bash",
            "      - name: Capture exact validated Control Hub source\n"
            "        env:\n"
            "          BASH_ENV: /tmp/hook\n"
            "        shell: bash",
            1,
        )
        self.assert_rejected(weakened)

    def test_shell_override_rejected(self):
        weakened = self.text.replace(
            "        shell: bash",
            "        shell: sh",
            1,
        )
        self.assert_rejected(weakened)

    def test_second_capture_invocation_rejected(self):
        needle = (
            "          python3 afz-openai-agent/control/"
            "radiohilal_hpenvy_controlhub_capture.py \\\n"
            '            --output "${RUNNER_TEMP}/radiohilal-controlhub-capture"'
        )
        weakened = self.text.replace(needle, needle + "\n" + needle, 1)
        self.assertNotEqual(weakened, self.text)
        self.assert_rejected(weakened)

    def test_extra_unnamed_run_step_rejected(self):
        weakened = self.text.replace(
            "      - name: Upload validated read-only capture",
            "      - run: echo unexpected\n"
            "      - name: Upload validated read-only capture",
            1,
        )
        self.assert_rejected(weakened)

    def test_extra_capture_run_line_rejected(self):
        weakened = self.text.replace(
            '            --output "${RUNNER_TEMP}/radiohilal-controlhub-capture"',
            '            --output "${RUNNER_TEMP}/radiohilal-controlhub-capture"\n'
            "          echo unexpected",
            1,
        )
        self.assert_rejected(weakened)

    def test_capture_step_if_rejected(self):
        weakened = self.text.replace(
            "      - name: Capture exact validated Control Hub source\n"
            "        shell: bash",
            "      - name: Capture exact validated Control Hub source\n"
            "        if: true\n"
            "        shell: bash",
            1,
        )
        self.assert_rejected(weakened)

    def test_validation_extra_run_line_rejected(self):
        weakened = self.text.replace(
            "          python3 afz-openai-agent/control/"
            "test_radiohilal_hpenvy_controlhub_capture.py -v",
            "          python3 afz-openai-agent/control/"
            "test_radiohilal_hpenvy_controlhub_capture.py -v\n"
            "          echo unexpected",
            1,
        )
        self.assert_rejected(weakened)

    def test_embedded_remote_ssh_rejected(self):
        weakened = self.text.replace(
            "          set -euo pipefail\n"
            "          python3 afz-openai-agent/control/",
            "          set -euo pipefail\n"
            "          tailscale ssh coolyo@100.71.26.69 'bash -s'\n"
            "          python3 afz-openai-agent/control/",
            1,
        )
        self.assert_rejected(weakened)

    def test_second_upload_action_rejected(self):
        weakened = self.text + (
            "\n      - name: Extra upload\n"
            "        uses: actions/upload-artifact@v4\n"
            "        with:\n"
            "          path: extra.txt\n"
        )
        self.assert_rejected(weakened)

    def test_extra_upload_path_rejected(self):
        weakened = self.text.replace(
            "            ${{ runner.temp }}/radiohilal-controlhub-capture/sha256.txt",
            "            ${{ runner.temp }}/radiohilal-controlhub-capture/sha256.txt\n"
            "            ${{ runner.temp }}/radiohilal-controlhub-capture/extra.txt",
            1,
        )
        self.assert_rejected(weakened)

    def test_directory_wide_upload_rejected(self):
        start = (
            "            ${{ runner.temp }}/radiohilal-controlhub-capture/"
            "controlhub-source.zip"
        )
        weakened = self.text.replace(
            start,
            "            ${{ runner.temp }}/radiohilal-controlhub-capture/",
            1,
        )
        self.assert_rejected(weakened)


if __name__ == "__main__":
    unittest.main()

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


def validate_workflow_text(text: str) -> None:
    lines = text.splitlines()
    top_keys = []
    for line in lines:
        if line and not line.startswith(" ") and ":" in line:
            top_keys.append(line.split(":", 1)[0])
    if top_keys != ["name", "on", "permissions", "concurrency", "jobs"]:
        raise ValueError(f"top-level workflow structure invalid: {top_keys}")

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
    validate_uses = [
        line.strip()[len("- uses: ") :]
        for line in validate_lines
        if line.strip().startswith("- uses: ")
    ]
    if validate_uses != ["actions/checkout@v4"]:
        raise ValueError(f"validation action set invalid: {validate_uses}")

    capture_text = "\n".join(capture_lines)
    capture_header_end = capture_lines.index("    steps:")
    capture_header = capture_lines[:capture_header_end]
    if "    needs: validate-readonly-boundary" not in capture_header:
        raise ValueError("capture dependency missing")
    condition_lines = [
        line.strip()
        for line in capture_header
        if line.strip().startswith("if:")
    ]
    if condition_lines != ["if: github.event_name == 'workflow_dispatch'"]:
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

    capture_names = [
        line.strip()[len("- name: ") :]
        for line in capture_lines
        if line.strip().startswith("- name: ")
    ]
    if capture_names != [
        "Join AFZ tailnet",
        "Capture exact validated Control Hub source",
        "Upload validated read-only capture",
    ]:
        raise ValueError(f"capture step names invalid: {capture_names}")

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
    if set(upload_paths) != EXPECTED_UPLOAD_PATHS or len(upload_paths) != len(EXPECTED_UPLOAD_PATHS):
        raise ValueError(f"upload path set invalid: {upload_paths}")
    if capture_text.count("actions/upload-artifact@v4") != 1:
        raise ValueError("upload action count invalid")
    if "          retention-days: 7" not in upload_lines:
        raise ValueError("artifact retention invalid")
    if "          if-no-files-found: error" not in upload_lines:
        raise ValueError("artifact missing-file policy invalid")


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

    def test_function_default_secret_rejected(self):
        self.scan_reject("def f(password='ordinary-value'):\n    return password\n")

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


def listing(size: int, mode: str = "-rw-r--r--") -> str:
    return (
        f"{mode}    1 1000 1000 {size} "
        f"Sep 19 02:00 {cap.REMOTE_PATH}"
    )


class SftpPureTests(unittest.TestCase):
    def test_batch_is_fixed_read_only_and_double_reads(self):
        batch = cap.build_sftp_batch()
        commands = [
            line.lstrip("@").split(None, 1)[0]
            for line in batch.splitlines()
            if line.strip()
        ]
        self.assertEqual(commands, ["ls", "get", "ls", "get", "ls", "quit"])
        for forbidden in ("put", "rm", "rename", "mkdir", "chmod", "chown", "ln"):
            self.assertNotRegex(batch, rf"(?m)^@?{forbidden}\b")
        self.assertEqual(batch.count(cap.REMOTE_PATH), 5)

    def test_transport_wrapper_is_fixed_to_sftp_subsystem(self):
        wrapper = cap.build_transport_wrapper(
            python_path="/usr/bin/python3",
            tailscale_path="/usr/bin/tailscale",
        )
        compile(wrapper, "<transport-wrapper>", "exec")
        self.assertIn('args[-4:] != ["-s", "--", HOST, "sftp"]', wrapper)
        self.assertIn('"ssh"', wrapper)
        self.assertIn('"-s"', wrapper)
        self.assertIn('"sftp"', wrapper)
        self.assertNotIn(cap.REMOTE_PATH, wrapper)
        self.assertNotIn("bash", wrapper)
        self.assertNotIn("tar", wrapper)

    def test_transport_wrapper_rejects_wrong_subsystem_without_exec(self):
        wrapper = cap.build_transport_wrapper(
            python_path=sys.executable,
            tailscale_path=sys.executable,
        )
        with tempfile.TemporaryDirectory() as td:
            script = pathlib.Path(td) / "transport.py"
            script.write_text(wrapper, encoding="utf-8")
            proc = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "-l",
                    "coolyo",
                    "-s",
                    "--",
                    cap.TARGET_HOST,
                    "shell",
                ],
                capture_output=True,
                timeout=5,
            )
        self.assertEqual(proc.returncode, 72)

    def test_metadata_regular_stable_passes(self):
        text = "\n".join([listing(321), listing(321), listing(321)]) + "\n"
        self.assertEqual(cap.parse_sftp_metadata(text), [321, 321, 321])

    def test_metadata_symlink_rejected(self):
        text = "\n".join(
            [listing(321), listing(321, "lrwxrwxrwx"), listing(321)]
        )
        with self.assertRaisesRegex(cap.CaptureError, "not a regular file"):
            cap.parse_sftp_metadata(text)

    def test_metadata_size_change_rejected(self):
        text = "\n".join([listing(321), listing(322), listing(321)])
        with self.assertRaisesRegex(cap.CaptureError, "changed size"):
            cap.parse_sftp_metadata(text)

    def test_metadata_extra_listing_rejected(self):
        text = "\n".join(
            [listing(321), listing(321), listing(321), listing(321)]
        )
        with self.assertRaisesRegex(cap.CaptureError, "exactly three"):
            cap.parse_sftp_metadata(text)

    def test_metadata_wrong_target_rejected(self):
        text = "\n".join([listing(321), listing(321), listing(321)])
        text = text.replace(cap.REMOTE_PATH, "/etc/passwd", 1)
        with self.assertRaisesRegex(cap.CaptureError, "unexpected remote"):
            cap.parse_sftp_metadata(text)

    def test_metadata_bound_rejected(self):
        with self.assertRaises(cap.CaptureError):
            cap.parse_sftp_metadata("x" * (cap.MAX_METADATA_BYTES + 1))


@unittest.skipUnless(os.name == "posix", "POSIX subprocess/resource test")
class SftpPosixTests(unittest.TestCase):
    @mock.patch.object(cap.subprocess, "run")
    @mock.patch.object(cap.shutil, "which")
    def test_fetch_uses_sftp_wrapper_size_limit_and_double_read(self, which, run):
        which.side_effect = lambda name: {
            "sftp": "/usr/bin/sftp",
            "tailscale": "/usr/bin/tailscale",
        }[name]
        payload = b"print('safe')\n"

        def fake_run(args, **kwargs):
            stage = pathlib.Path(kwargs["cwd"])
            (stage / "main.first").write_bytes(payload)
            (stage / "main.second").write_bytes(payload)
            meta = "\n".join(
                [listing(len(payload)), listing(len(payload)), listing(len(payload))]
            ) + "\n"
            kwargs["stdout"].write(meta.encode("utf-8"))
            kwargs["stdout"].flush()
            self.assertNotIn("shell", kwargs)
            self.assertIs(kwargs["stdin"], subprocess.DEVNULL)
            self.assertIs(kwargs["stderr"], subprocess.DEVNULL)
            self.assertTrue(callable(kwargs["preexec_fn"]))
            self.assertEqual(args[0], "/usr/bin/sftp")
            self.assertIn("-S", args)
            self.assertEqual(args[-1], cap.TARGET)
            batch = pathlib.Path(args[args.index("-b") + 1]).read_text()
            self.assertEqual(batch, cap.build_sftp_batch())
            wrapper = pathlib.Path(args[args.index("-S") + 1]).read_text()
            self.assertIn('"-s"', wrapper)
            self.assertIn('"sftp"', wrapper)
            return SimpleNamespace(returncode=0)

        run.side_effect = fake_run
        with tempfile.TemporaryDirectory() as td:
            result = cap.fetch_source_via_sftp(pathlib.Path(td))
        self.assertEqual(result, payload)

    @mock.patch.object(cap.subprocess, "run")
    @mock.patch.object(cap.shutil, "which")
    def test_double_read_content_change_rejected(self, which, run):
        which.side_effect = lambda name: {
            "sftp": "/usr/bin/sftp",
            "tailscale": "/usr/bin/tailscale",
        }[name]

        def fake_run(args, **kwargs):
            stage = pathlib.Path(kwargs["cwd"])
            (stage / "main.first").write_bytes(b"AAAA")
            (stage / "main.second").write_bytes(b"BBBB")
            kwargs["stdout"].write(
                ("\n".join([listing(4), listing(4), listing(4)]) + "\n").encode()
            )
            kwargs["stdout"].flush()
            return SimpleNamespace(returncode=0)

        run.side_effect = fake_run
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaisesRegex(cap.CaptureError, "changed during capture"):
                cap.fetch_source_via_sftp(pathlib.Path(td))


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
            self.assertEqual(manifest["transport"], "tailscale-ssh-sftp-subsystem")
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
                    "fetch_source_via_sftp",
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
            "if: github.event_name == 'workflow_dispatch'",
            "if: true",
            1,
        )
        self.assert_rejected(weakened)

    def test_validation_permission_override_rejected(self):
        weakened = self.text.replace(
            "    timeout-minutes: 2\n    steps:",
            "    timeout-minutes: 2\n    permissions:\n      id-token: write\n"
            "    steps:",
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

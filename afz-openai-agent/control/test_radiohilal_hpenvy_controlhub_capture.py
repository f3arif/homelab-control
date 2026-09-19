import base64
import hashlib
import json
import os
import pathlib
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


def envelope(files: dict[str, bytes] | None = None) -> dict:
    files = files or {
        "app/main.py": b"import os\nAFZ_HUB_TOKEN = os.getenv('AFZ_HUB_TOKEN')\n"
    }
    rows = []
    for name, data in files.items():
        rows.append(
            {
                "name": name,
                "size": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
                "data_b64": base64.b64encode(data).decode("ascii"),
            }
        )
    return {
        "schema": "afz-controlhub-source-capture-v1",
        "host": "hpenvy",
        "user": "coolyo",
        "files": rows,
    }


def validate_workflow_text(text: str) -> None:
    if "\njobs:\n" not in text:
        raise ValueError("jobs structure missing")
    header, jobs = text.split("\njobs:\n", 1)

    if "workflow_dispatch:" not in header or "pull_request:" not in header:
        raise ValueError("required trigger missing")
    permissions = header.split("\npermissions:\n", 1)
    if len(permissions) != 2:
        raise ValueError("root permissions missing")
    root_perm = permissions[1].split("\n\n", 1)[0].strip()
    if root_perm != "contents: read":
        raise ValueError("root permissions widened")

    marker = "\n  capture:\n"
    if marker not in jobs:
        raise ValueError("capture job missing")
    validate_job, capture = jobs.split(marker, 1)

    validate_required = (
        "validate-readonly-boundary:",
        "runs-on: ubuntu-latest",
        "python3 -m py_compile "
        "afz-openai-agent/control/radiohilal_hpenvy_controlhub_capture.py "
        "afz-openai-agent/control/test_radiohilal_hpenvy_controlhub_capture.py",
        "python3 afz-openai-agent/control/test_radiohilal_hpenvy_controlhub_capture.py -v",
    )
    for token in validate_required:
        if token not in validate_job:
            raise ValueError(f"validation contract missing: {token}")

    capture_header, capture_steps = capture.split("\n    steps:\n", 1)
    for token in (
        "needs: validate-readonly-boundary",
        "if: github.event_name == 'workflow_dispatch'",
        "contents: read",
        "id-token: write",
    ):
        if token not in capture_header:
            raise ValueError(f"capture gate missing: {token}")
    if capture_header.count("id-token: write") != 1:
        raise ValueError("capture id-token permission malformed")

    if "tailscale/github-action@v4" not in capture_steps:
        raise ValueError("tailnet action missing")
    if "tailscale ssh" in capture_steps:
        raise ValueError("workflow must not embed remote shell")
    if "radiohilal_hpenvy_controlhub_capture.py" not in capture_steps:
        raise ValueError("capture client invocation missing")
    exact_output = '--output "${RUNNER_TEMP}/radiohilal-controlhub-capture"'
    if exact_output not in capture_steps:
        raise ValueError("capture output path invalid")

    if "actions/upload-artifact@v4" not in capture_steps:
        raise ValueError("artifact upload step missing")
    upload_required = tuple(
        "${{ runner.temp }}/radiohilal-controlhub-capture/" + name
        for name in cap.OUTPUT_NAMES
    )
    for item in upload_required:
        if item not in capture_steps:
            raise ValueError(f"explicit artifact output missing: {item}")

    directory_only = "${{ runner.temp }}/radiohilal-controlhub-capture/"
    lines = [line.strip() for line in capture_steps.splitlines()]
    if directory_only in lines:
        raise ValueError("directory-wide artifact upload forbidden")

    forbidden = (
        "systemctl ",
        "service ",
        "docker compose",
        "sudo ",
        "curl -X POST",
        "curl --request POST",
        "curl -X PUT",
        "curl -X PATCH",
        "curl -X DELETE",
    )
    if any(token in capture_steps for token in forbidden):
        raise ValueError("workflow contains forbidden mutation surface")


class SecretScanTests(unittest.TestCase):
    def test_safe_python_env_lookup_passes(self):
        cap.scan_sources(
            {
                "app/main.py": (
                    b"import os\n"
                    b"AFZ_HUB_TOKEN = os.getenv('AFZ_HUB_TOKEN')\n"
                    b"PASSWORD = os.environ.get('PASSWORD')\n"
                )
            }
        )

    def assert_python_rejected(self, source: str):
        with self.assertRaises(cap.CaptureError):
            cap.scan_sources({"app/main.py": source.encode("utf-8")})

    def test_python_env_default_secret_rejected(self):
        self.assert_python_rejected(
            "import os\n"
            "AFZ_HUB_TOKEN = os.getenv('AFZ_HUB_TOKEN', 'hardcoded-value')\n"
        )

    def test_python_annotated_secret_rejected(self):
        self.assert_python_rejected("AFZ_HUB_TOKEN: str = 'hardcoded'\n")

    def test_short_password_rejected(self):
        self.assert_python_rejected("password = 'x'\n")

    def test_dict_secret_literal_rejected(self):
        self.assert_python_rejected("cfg = {'client_secret': 'abc'}\n")

    def test_sensitive_function_default_rejected(self):
        self.assert_python_rejected("def f(password='x'):\n    return password\n")

    def test_generic_token_prefix_rejected(self):
        self.assert_python_rejected(
            "value = 'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ12'\n"
        )

    def test_private_key_rejected(self):
        self.assert_python_rejected(
            "value = '''-----BEGIN PRIVATE KEY-----\nabc\n'''\n"
        )

    def test_credential_url_rejected(self):
        self.assert_python_rejected(
            "value = 'postgres://user:password@db.example/db'\n"
        )

    def test_pyproject_sensitive_value_rejected(self):
        with self.assertRaises(cap.CaptureError):
            cap.scan_sources(
                {
                    "app/main.py": b"x = 1\n",
                    "pyproject.toml": b"[tool.afz]\napi_key='hardcoded'\n",
                }
            )

    def test_dockerfile_multi_env_secret_rejected(self):
        with self.assertRaises(cap.CaptureError):
            cap.scan_sources(
                {
                    "app/main.py": b"x = 1\n",
                    "Dockerfile": (
                        b"FROM python:3.12\n"
                        b"ENV MODE=production AFZ_HUB_TOKEN=hardcoded\n"
                    ),
                }
            )

    def test_dockerfile_env_reference_allowed(self):
        cap.scan_sources(
            {
                "app/main.py": b"x = 1\n",
                "Dockerfile": (
                    b"FROM python:3.12\n"
                    b"ENV AFZ_HUB_TOKEN=${AFZ_HUB_TOKEN}\n"
                ),
            }
        )


class EnvelopeTests(unittest.TestCase):
    def test_valid_envelope_decodes(self):
        files = cap.validate_envelope(envelope())
        self.assertIn("app/main.py", files)

    def test_unknown_file_rejected(self):
        with self.assertRaises(cap.CaptureError):
            cap.validate_envelope(envelope({"app/main.py": b"x=1\n", "x.txt": b"x"}))

    def test_duplicate_file_rejected(self):
        obj = envelope()
        obj["files"].append(dict(obj["files"][0]))
        with self.assertRaises(cap.CaptureError):
            cap.validate_envelope(obj)

    def test_bad_hash_rejected(self):
        obj = envelope()
        obj["files"][0]["sha256"] = "0" * 64
        with self.assertRaises(cap.CaptureError):
            cap.validate_envelope(obj)

    def test_extra_record_field_rejected(self):
        obj = envelope()
        obj["files"][0]["extra"] = True
        with self.assertRaises(cap.CaptureError):
            cap.validate_envelope(obj)

    def test_extra_top_level_field_rejected(self):
        obj = envelope()
        obj["extra"] = True
        with self.assertRaises(cap.CaptureError):
            cap.validate_envelope(obj)

    def test_required_main_missing_rejected(self):
        with self.assertRaises(cap.CaptureError):
            cap.validate_envelope(envelope({"requirements.txt": b"fastapi\n"}))


class OutputTests(unittest.TestCase):
    def test_fresh_output_required(self):
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            existing = root / "out"
            existing.mkdir()
            with self.assertRaises(cap.CaptureError):
                cap.prepare_output_dir(existing)

    def test_deterministic_zip_and_exact_outputs(self):
        files = {
            "app/main.py": b"x = 1\n",
            "requirements.txt": b"fastapi==1\n",
        }
        health = {
            "service": "afz-control-hub",
            "mode": "safe-readonly",
            "version": "0.3.3-safe-typed-canary",
        }
        with tempfile.TemporaryDirectory() as td:
            root = pathlib.Path(td)
            out1 = root / "a"
            out2 = root / "b"
            cap.emit_outputs(out1, files, health)
            cap.emit_outputs(out2, files, health)
            self.assertEqual(
                {p.name for p in out1.iterdir()}, set(cap.OUTPUT_NAMES)
            )
            with zipfile.ZipFile(out1 / "controlhub-source.zip") as zf:
                self.assertEqual(
                    zf.namelist(), ["app/main.py", "requirements.txt"]
                )
                for info in zf.infolist():
                    self.assertEqual(info.date_time, (1980, 1, 1, 0, 0, 0))
                    self.assertFalse(info.is_dir())
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
            self.assertFalse(manifest["secret_values_emitted"])
            self.assertFalse(manifest["remote_mutation_performed"])


class RemoteCommandTests(unittest.TestCase):
    def test_embedded_remote_reader_compiles_and_uses_nofollow(self):
        compile(cap.REMOTE_READER, '<remote-reader>', 'exec')
        self.assertIn('O_NOFOLLOW', cap.REMOTE_READER)
        self.assertIn('os.fstat', cap.REMOTE_READER)
        self.assertNotIn('read_bytes()', cap.REMOTE_READER)

    def test_remote_command_is_sanitized_and_has_no_tar(self):
        command = cap.build_remote_command()
        for token in (
            "unset BASH_ENV ENV TAR_OPTIONS",
            "/usr/bin/env -i",
            "LANG=C LC_ALL=C",
            "/usr/bin/python3 -I -S -c",
        ):
            self.assertIn(token, command)
        for token in (" tar ", "systemctl", "docker", "sudo", "curl "):
            self.assertNotIn(token, command)

    @mock.patch.object(cap.subprocess, "run")
    def test_fetch_uses_list_args_no_shell_and_sanitized_env(self, run):
        payload = json.dumps(envelope(), separators=(",", ":")).encode()
        run.return_value = SimpleNamespace(returncode=0, stdout=payload)
        old = os.environ.get("BASH_ENV")
        try:
            os.environ["BASH_ENV"] = "danger"
            obj = cap.fetch_remote_envelope()
        finally:
            if old is None:
                os.environ.pop("BASH_ENV", None)
            else:
                os.environ["BASH_ENV"] = old
        self.assertEqual(obj["host"], "hpenvy")
        args, kwargs = run.call_args
        self.assertIsInstance(args[0], list)
        self.assertEqual(args[0][:3], ["tailscale", "ssh", cap.TARGET])
        self.assertNotIn("shell", kwargs)
        self.assertIs(kwargs["stderr"], subprocess.DEVNULL)
        self.assertIs(kwargs["stdin"], subprocess.DEVNULL)
        self.assertNotIn("BASH_ENV", kwargs["env"])
        self.assertNotIn("TAR_OPTIONS", kwargs["env"])

    @mock.patch.object(cap.subprocess, "run")
    def test_remote_stderr_is_never_exposed_on_failure(self, run):
        run.return_value = SimpleNamespace(
            returncode=7, stdout=b"possible-secret-output"
        )
        with self.assertRaisesRegex(cap.CaptureError, "exit 7") as ctx:
            cap.fetch_remote_envelope()
        self.assertNotIn("possible-secret-output", str(ctx.exception))


class WorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")

    def test_current_workflow_contract(self):
        validate_workflow_text(self.text)

    def assert_weakened_rejected(self, text: str):
        with self.assertRaises(ValueError):
            validate_workflow_text(text)

    def test_missing_needs_rejected(self):
        self.assert_weakened_rejected(
            self.text.replace(
                "    needs: validate-readonly-boundary\n", "", 1
            )
        )

    def test_capture_enabled_on_pr_rejected(self):
        self.assert_weakened_rejected(
            self.text.replace(
                "    if: github.event_name == 'workflow_dispatch'",
                "    if: true",
                1,
            )
        )

    def test_root_oidc_permission_rejected(self):
        self.assert_weakened_rejected(
            self.text.replace(
                "permissions:\n  contents: read",
                "permissions:\n  contents: read\n  id-token: write",
                1,
            )
        )

    def test_directory_wide_upload_rejected(self):
        explicit = "\n".join(
            "            ${{ runner.temp }}/radiohilal-controlhub-capture/" + name
            for name in cap.OUTPUT_NAMES
        )
        weakened = self.text.replace(
            explicit,
            "            ${{ runner.temp }}/radiohilal-controlhub-capture/",
            1,
        )
        self.assertNotEqual(weakened, self.text)
        self.assert_weakened_rejected(weakened)

    def test_remote_shell_in_workflow_rejected(self):
        weakened = self.text.replace(
            "          python3 afz-openai-agent/control/"
            "radiohilal_hpenvy_controlhub_capture.py \\\n"
            '            --output "${RUNNER_TEMP}/radiohilal-controlhub-capture"',
            "          tailscale ssh coolyo@100.71.26.69 'bash -s'",
            1,
        )
        self.assertNotEqual(weakened, self.text)
        self.assert_weakened_rejected(weakened)

    def test_capture_client_invocation_removal_rejected(self):
        before, sep, after = self.text.rpartition(
            "radiohilal_hpenvy_controlhub_capture.py"
        )
        self.assertTrue(sep)
        weakened = before + "other_capture.py" + after
        self.assert_weakened_rejected(weakened)


class HealthTests(unittest.TestCase):
    @mock.patch.object(cap.urllib.request, "urlopen")
    def test_health_returns_only_bounded_allowlist(self, urlopen):
        body = json.dumps(
            {
                "ok": True,
                "service": "afz-control-hub",
                "mode": "safe-readonly",
                "version": "0.3.3-safe-typed-canary",
                "extra": "not returned",
            }
        ).encode()
        response = mock.MagicMock()
        response.status = 200
        response.read.return_value = body
        response.__enter__.return_value = response
        urlopen.return_value = response
        result = cap.check_health()
        self.assertEqual(
            result,
            {
                "service": "afz-control-hub",
                "mode": "safe-readonly",
                "version": "0.3.3-safe-typed-canary",
            },
        )

    @mock.patch.object(cap.urllib.request, "urlopen")
    def test_health_multiline_or_unbounded_version_rejected(self, urlopen):
        body = json.dumps(
            {
                "ok": True,
                "service": "afz-control-hub",
                "mode": "safe-readonly",
                "version": "good\nsecret",
            }
        ).encode()
        response = mock.MagicMock()
        response.status = 200
        response.read.return_value = body
        response.__enter__.return_value = response
        urlopen.return_value = response
        with self.assertRaises(cap.CaptureError):
            cap.check_health()


if __name__ == "__main__":
    unittest.main()

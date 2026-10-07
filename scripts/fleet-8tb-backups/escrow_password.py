#!/usr/bin/env python3
"""Create a private restic password and verify a Windows user-DPAPI copy.

The password travels only on verified SSH stdin. It is never a command argument
or log field. Existing passwords and escrow files are never overwritten.
Windows DPAPI recovery requires the same Windows user profile and its keys.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import secrets
import stat
import subprocess

from guard_volume import load_profile, query_volume, ssh_command, validate_volume


def psquote(text):
    return "'" + text.replace("'", "''") + "'"


def password_bytes(path):
    path = Path(path)
    if not path.is_absolute() or any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError("unsafe_password_path")
    parent = path.parent.stat()
    if parent.st_uid != os.getuid() or stat.S_IMODE(parent.st_mode) & 0o077:
        raise ValueError("password_parent_must_be_private")
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError:
        pass
    else:
        with os.fdopen(fd, "wb") as stream:
            stream.write(secrets.token_urlsafe(48).encode("ascii") + b"\n")
            stream.flush()
            os.fsync(stream.fileno())
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        st = os.fstat(stream.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o600:
            raise ValueError("password_must_be_owned_regular_0600")
        value = stream.read(4097).strip()
    if not 32 <= len(value) <= 4096 or any(c not in b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_" for c in value):
        raise ValueError("invalid_generated_password_format")
    return value


def escrow_command(profile):
    path = profile["escrow_windows_path"]
    winpath = PureWindowsPath(path)
    if (not winpath.is_absolute() or winpath.drive.upper() != profile["drive_letter"] + ":"
            or ".." in winpath.parts or any(c in path for c in "\x00\r\n")):
        raise ValueError("invalid_escrow_path")
    script = r"""
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
function AssertVolume {
  $v=Get-Volume -DriveLetter __LETTER__ -ErrorAction Stop
  $guid=([string]$v.UniqueId).ToLowerInvariant()
  if(!$guid.Contains(__GUID__) -or [string]$v.FileSystemLabel -cne __LABEL__ -or [int64]$v.SizeRemaining -lt __RESERVE__){throw 'volume_guard_failed'}
}
AssertVolume
$path=__PATH__
$plain=[Console]::In.ReadToEnd().TrimEnd([char[]]@([char]10,[char]13))
if($plain.Length -lt 32 -or $plain.Length -gt 4096){throw 'password_length'}
if(!(Test-Path -LiteralPath $path)){
  $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
  $secure=ConvertTo-SecureString -String $plain -AsPlainText -Force
  $cipher=ConvertFrom-SecureString -SecureString $secure
  $bytes=[Text.UTF8Encoding]::new($false).GetBytes($cipher)
  $f=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{$f.Write($bytes,0,$bytes.Length);$f.Flush($true)}finally{$f.Dispose()}
}
$restored=ConvertTo-SecureString -String ([IO.File]::ReadAllText($path))
$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($restored)
try{
  $again=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
  if($again -cne $plain){throw 'escrow_mismatch'}
  $sha=[Security.Cryptography.SHA256]::Create()
  try{$hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($again)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
AssertVolume
[pscustomobject]@{verified=$true;password_sha256=$hash;protection='Windows user DPAPI'}|ConvertTo-Json -Compress
"""
    for key, value in {
        "__LETTER__": psquote(profile["drive_letter"]),
        "__GUID__": psquote(profile["volume_guid"].lower()),
        "__LABEL__": psquote(profile["volume_label"]),
        "__RESERVE__": str(profile["min_free_bytes"]),
        "__PATH__": psquote(path),
    }.items():
        script = script.replace(key, value)
    command = ssh_command(profile)
    command[-1] = "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand " + base64.b64encode(script.encode("utf-16le")).decode("ascii")
    return command


def escrow(profile):
    validate_volume(profile, query_volume(profile))
    password = password_bytes(profile["password_file"])
    result = subprocess.run(escrow_command(profile), input=password + b"\n", capture_output=True, timeout=40)
    if result.returncode:
        raise RuntimeError("escrow_transport_or_protection_failed")
    answer = json.loads(result.stdout.decode("utf-8-sig"))
    if answer.get("verified") is not True or answer.get("password_sha256") != hashlib.sha256(password).hexdigest():
        raise RuntimeError("escrow_verification_failed")
    return {"ok": True, "escrow_verified": True, "protection": "Windows user DPAPI",
            "recovery_requires": "Original Windows user profile and its DPAPI keys"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    args = parser.parse_args()
    try:
        result = escrow(load_profile(args.profile))
    except Exception as exc:
        print(json.dumps({"ok": False, "error_type": type(exc).__name__, "error": "password_escrow_failed"}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

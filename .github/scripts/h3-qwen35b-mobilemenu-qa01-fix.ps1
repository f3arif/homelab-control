$ErrorActionPreference='Stop'
$src='C:\Projects\Qwen36-35B-A3B-Website-Test-20260830-r1-repair01'
$qa='C:\Projects\Qwen36-35B-A3B-Website-Test-20260830-r1-repair01-qa01'
$task='AFZ Qwen35B Website Preview'
$state='C:\ProgramData\AFZ\H3Qwen35BPreview'
$runner=Join-Path $state 'Start-Preview.cmd'
$port=3108
if(-not(Test-Path -LiteralPath $src -PathType Container)){throw 'Original Repair01 root missing'}

New-Item -ItemType Directory -Force -Path $qa|Out-Null
& robocopy.exe $src $qa /E /R:1 /W:1 /XD node_modules .next AFZ-QUALITY-CAPTURE /XF server.log server.stdout.log server.stderr.log | Out-Null
if($LASTEXITCODE -ge 8){throw "robocopy failed exit=$LASTEXITCODE"}

$header=Join-Path $qa 'src\components\Header.tsx'
$headerText=@"
"use client";

import Link from "next/link";
import { useState } from "react";
import { Menu } from "lucide-react";
import MobileNav from "./MobileNav";

const navLinks = [
  { name: "Home", href: "/" },
  { name: "Services", href: "/services" },
  { name: "Projects", href: "/projects" },
  { name: "About", href: "/about" },
  { name: "Contact", href: "/contact" },
];

export default function Header() {
  const [isOpen, setIsOpen] = useState(false);

  return (
    <>
      <header className="fixed top-0 w-full bg-white/95 backdrop-blur-sm border-b border-slate-200 z-50">
        <div className="max-w-7xl mx-auto px-6 h-20 flex items-center justify-between">
          <Link href="/" className="flex items-center gap-2 group">
            <div className="w-8 h-8 bg-blue-900 text-white flex items-center justify-center font-bold rounded-sm">AFZ</div>
            <span className="text-xl font-bold text-slate-900 tracking-tight group-hover:text-blue-700 transition-colors">Engineering Inc.</span>
          </Link>
          <nav className="hidden md:flex items-center gap-8">
            {navLinks.map((link) => (
              <Link key={link.name} href={link.href} className="text-sm font-medium text-slate-600 hover:text-blue-700 transition-colors">{link.name}</Link>
            ))}
          </nav>
          <button className="md:hidden p-2 text-slate-600 hover:bg-slate-100 rounded-md" onClick={() => setIsOpen(true)} aria-label="Open Menu">
            <Menu size={24} />
          </button>
        </div>
      </header>
      {isOpen && <MobileNav onClose={() => setIsOpen(false)} />}
    </>
  );
}
"@
[IO.File]::WriteAllText($header,$headerText,(New-Object Text.UTF8Encoding($false)))

$npm=(Get-Command npm.cmd -ErrorAction Stop).Source
Push-Location $qa
try {
  if(Test-Path -LiteralPath (Join-Path $qa 'package-lock.json')) { & $npm ci --no-audit --no-fund }
  else { & $npm install --no-audit --no-fund }
  if($LASTEXITCODE -ne 0){throw "npm dependency install failed exit=$LASTEXITCODE"}
  & $npm run build
  if($LASTEXITCODE -ne 0){throw "QA01 build failed exit=$LASTEXITCODE"}
} finally { Pop-Location }

& schtasks.exe /End /TN $task 2>$null | Out-Null
Start-Sleep -Seconds 2
$l=Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue|Select-Object -First 1
if($l){
  $proc=Get-CimInstance Win32_Process -Filter "ProcessId=$($l.OwningProcess)" -ErrorAction SilentlyContinue
  if($proc -and $proc.Name -eq 'node.exe' -and ([string]$proc.CommandLine -match 'Qwen36-35B-A3B-Website-Test-20260830-r1')){
    Stop-Process -Id $l.OwningProcess -Force -ErrorAction Stop
    Start-Sleep -Seconds 1
  } else { throw "Port $port is held by an unexpected process" }
}

$node=(Get-Command node.exe -ErrorAction Stop).Source
$next=Join-Path $qa 'node_modules\next\dist\bin\next'
$stdout=Join-Path $state 'server.stdout.log'
$stderr=Join-Path $state 'server.stderr.log'
$cmd="@echo off`r`ncd /d `"$qa`"`r`n`"$node`" `"$next`" start -H 127.0.0.1 -p $port 1>>`"$stdout`" 2>>`"$stderr`"`r`n"
[IO.File]::WriteAllText($runner,$cmd,(New-Object Text.ASCIIEncoding))
& schtasks.exe /Run /TN $task | Out-Null
if($LASTEXITCODE -ne 0){throw "preview task restart failed exit=$LASTEXITCODE"}

$ready=$false
for($i=0;$i -lt 45;$i++){
  Start-Sleep -Seconds 1
  try {$r=Invoke-WebRequest "http://127.0.0.1:$port/" -UseBasicParsing -TimeoutSec 4;if([int]$r.StatusCode -eq 200 -and $r.Content -match 'AFZ Engineering'){$ready=$true;break}} catch {}
}
if(-not $ready){throw 'QA01 preview did not become healthy'}

$l=Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop|Select-Object -First 1
"QA_ROOT=$qa"
"BUILD=PASS"
"LOCAL_HTTP=200"
"LISTEN_PID=$($l.OwningProcess)"
"ORIGINAL_REPAIR01_UNCHANGED=True"
"MODEL_CALL_ISSUED=False"
"QA_SITE_MUTATION=True"

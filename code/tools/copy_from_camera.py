#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
从 Nikon Z6II（MTP 模式）把指定视频复制到本地目录。

用法：
    python copy_from_camera.py DSC_3265 D:\\path\\to\\out

依赖 Windows Shell COM（win32com 或 ctypes）。

简化实现：用 PowerShell 的 Shell.Application 更可靠，本脚本只是备选。
"""
import sys
import os
import subprocess

PS_TEMPLATE = r'''
$ErrorActionPreference = 'Stop'
$shell = New-Object -ComObject Shell.Application
$myPC  = $shell.NameSpace(17)
$cam   = $myPC.Items() | Where-Object {{ $_.Name -match 'Z ?6_?2' }} | Select-Object -First 1
if (-not $cam) {{ throw 'camera not found' }}

$destDir = "{dest}"
New-Item -ItemType Directory -Path $destDir -Force | Out-Null
$dest = $shell.NameSpace($destDir)

function Find-Item($folder, $pattern, $depth) {{
    if ($depth -gt 3) {{ return $null }}
    foreach ($it in $folder.Items()) {{
        if ($it.IsFolder) {{
            $r = Find-Item $it.GetFolder $pattern ($depth + 1)
            if ($r) {{ return $r }}
        }} elseif ($it.Name -match $pattern) {{
            return $it
        }}
    }}
    return $null
}}

$root = $cam.GetFolder
$found = $null
foreach ($store in $root.Items()) {{
    $found = Find-Item $store.GetFolder "{pattern}" 0
    if ($found) {{ break }}
}}
if (-not $found) {{ throw 'video not found: {pattern}' }}

Write-Output ("found: " + $found.Name)
$dest.CopyHere($found, 16)
Write-Output "copy started (async)"
'''


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    pattern = sys.argv[1]
    dest = sys.argv[2].replace('\\', '\\\\')

    ps = PS_TEMPLATE.format(pattern=pattern, dest=dest)
    ps_file = os.path.join(os.environ.get('TEMP', '.'), 'copy_cam.ps1')
    with open(ps_file, 'w', encoding='utf-8-sig') as f:
        f.write(ps)

    r = subprocess.run(
        ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps_file],
        capture_output=True, text=True, encoding='utf-8', errors='replace')
    print(r.stdout)
    if r.returncode != 0:
        print(r.stderr)
    return r.returncode


if __name__ == '__main__':
    sys.exit(main())

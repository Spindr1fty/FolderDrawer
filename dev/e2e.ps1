param([int]$IX = 76, [int]$IY = 605, [int]$IW = 76, [int]$IH = 52)
# 真实桌面端到端：最小化窗口 → 悬停真实文件夹图标 → 级联 → 右键菜单 → 截图
# 注意：
#   · $IX/$IY/$IW/$IH 是桌面文件夹图标的屏幕坐标（px，按 100% DPI 测），随桌面布局变化：
#     先跑 `FolderDrawer.ahk -dump`（看 desktopinfo.txt 里的 iconRect）或 `-hit` 取自己的值。
#   · 想看 trace 轨迹：先把 FolderDrawer.ahk 里 CFG.Debug 改成 true（默认 false，trace.txt 不会生成）。
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MouseCtl {
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
}
"@

function Cap($out, $x, $y, $w, $h) {
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h))
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bmp.Dispose()
    "saved: $out"
}
function Go($x, $y) { [void][MouseCtl]::SetCursorPos($x, $y) }

$tag = Get-Date -Format "HHmmss"
$shotDir = "D:\desk\FolderDrawer\dev\shots"
New-Item -ItemType Directory -Force -Path $shotDir | Out-Null
function CapU($name, $x, $y, $w, $h) { Cap "$shotDir\$name-$tag.png" $x $y $w $h }

# 关掉可能残留的右键菜单
[System.Windows.Forms.SendKeys]::SendWait("{ESC}")
Start-Sleep -Milliseconds 300

# 1) 清场：杀掉所有 AutoHotkey 进程并确认归零
Remove-Item D:\desk\FolderDrawer\trace.txt -Force -ErrorAction SilentlyContinue
[System.Windows.Forms.SendKeys]::SendWait("{ESC}")
Start-Sleep -Milliseconds 300
taskkill /F /IM AutoHotkey64.exe 2>$null | Out-Null
taskkill /F /IM AutoHotkey32.exe 2>$null | Out-Null
Start-Sleep -Seconds 1
$left = @(Get-Process AutoHotkey* -ErrorAction SilentlyContinue)
"清场后残留进程数: $($left.Count)（必须为 0）"

# 2) 露出桌面
$sh = New-Object -ComObject Shell.Application
$sh.MinimizeAll()
Start-Sleep -Milliseconds 800

# 3) 启动正式实例，确认 boot 日志
Start-Process "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" -ArgumentList '/ErrorStdOut', 'D:\desk\FolderDrawer\FolderDrawer.ahk'
Start-Sleep -Seconds 2
"进程数: $(@(Get-Process AutoHotkey64 -ErrorAction SilentlyContinue).Count)（必须为 1）"
"--- boot ---"
if (Test-Path D:\desk\FolderDrawer\trace.txt) {
    Get-Content D:\desk\FolderDrawer\trace.txt -Encoding UTF8
} else {
    "（无 trace.txt：把 FolderDrawer.ahk 的 CFG.Debug 改成 true 才会有日志）"
}

# 4) 悬停桌面文件夹图标
$cx = $IX + [int]($IW / 2)
$cy = $IY + [int]($IH / 2)
Go $cx $cy
Start-Sleep -Milliseconds 1200
CapU "e2e-1-hover" 0 520 780 520

# 5) 移到面板第 1 行（文件夹）→ 级联展开
$px = $IX + $IW + 10
$py = $IY - 4
$rowY = $py + 30 + 10
Go ($px + 120) $rowY
Start-Sleep -Milliseconds 1300
CapU "e2e-2-cascade" 0 520 1150 520

# 6) 移入级联面板第 2 行
$subX = $px + 252 - 4
Go ($subX + 110) ($rowY + 22)
Start-Sleep -Milliseconds 900
CapU "e2e-3-sub" 0 520 1350 520

# 7) 右键菜单（在父面板第 3 行）
Go ($px + 120) ($rowY + 44)
Start-Sleep -Milliseconds 400
[void][MouseCtl]::mouse_event(0x08, 0, 0, 0, [IntPtr]::Zero)   # RIGHTDOWN
[void][MouseCtl]::mouse_event(0x10, 0, 0, 0, [IntPtr]::Zero)   # RIGHTUP
Start-Sleep -Milliseconds 800
CapU "e2e-4-menu" 0 400 1200 640

# 8) 还原窗口
$sh.UndoMinimizeAll()

"--- trace（面板开/关轨迹）---"
Get-Content D:\desk\FolderDrawer\trace.txt -Encoding UTF8 -ErrorAction SilentlyContinue

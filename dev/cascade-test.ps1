# 级联 / 右键菜单验证：用 dev\demodata 固定数据 + -test 冻结面板，位置完全可预测
# 注意：-test 会把主轮询（Watch）整个停掉（g.freeze），所以鼠标悬停不会产生高亮/级联；
#       截图里的级联来自 FolderDrawer 的 DebugCascade 自检（自动展开第 1 行并高亮子面板第 2 行），
#       鼠标只用于验证「右键菜单」（控件事件，不受 freeze 影响）。
# 前提：系统缩放 100%。其它 DPI 下 S() 会把版式等比放大，下面的坐标需按 A_ScreenDPI/96 同比例换算。
# 坐标推导（对应 FolderDrawer.ahk 里 Peek.__New 的版式度量）：
#   -test 400 300 → 锚点矩形 {360,260,400,300} → 面板 x = 400+Gap(12) = 412，y = 260-8 = 252
#   标题 46 + 分组标签 24 + 行高 32 → 第 i 行（0 起）顶部 y = 252+46+24+32i，行中心再 +16
#   demodata 排序后前三行是文件夹：备份 2025 / 设计稿 / 项目资料，之后是文件
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MouseCtl2 {
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
}
"@

function CapU($name, $x, $y, $w, $h) {
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h))
    $out = "D:\desk\FolderDrawer\dev\shots\$name-$(Get-Date -Format HHmmss).png"
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bmp.Dispose()
    "saved: $out"
}
function Go($x, $y) { [void][MouseCtl2]::SetCursorPos($x, $y) }
New-Item -ItemType Directory -Force -Path D:\desk\FolderDrawer\dev\shots | Out-Null

# 版式坐标
$panelX = 412; $panelY = 252; $panelW = 300
$headH = 46; $labelH = 24; $rowH = 32; $padX = 10
$rowTop = $panelY + $headH + $labelH                 # 322：第一行顶部
$row2Y  = $rowTop + $rowH * 2 + [int]($rowH / 2)     # 402：第 3 行「项目资料」中心
$fileRowY = $rowTop + $rowH * 3 + $labelH + [int]($rowH / 2)   # 458：文件分组第一行中心
$subX = $panelX + $panelW - $padX + 12               # 714：子面板贴第 1 行右缘 + Gap
$subY = $rowTop - 8                                  # 314：子面板顶部

Remove-Item D:\desk\FolderDrawer\trace.txt -Force -ErrorAction SilentlyContinue
[System.Windows.Forms.SendKeys]::SendWait("{ESC}")
Start-Sleep -Milliseconds 500
taskkill /F /IM AutoHotkey64.exe 2>$null | Out-Null
Start-Sleep -Seconds 1

Start-Process "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" -ArgumentList '/ErrorStdOut', 'D:\desk\FolderDrawer\FolderDrawer.ahk', '-test', '400', '300', 'D:\desk\FolderDrawer\dev\demodata'
Start-Sleep -Seconds 2
Go 400 300
Start-Sleep -Milliseconds 600
CapU "cas-1-open" 200 150 900 700

# DebugCascade 已展开第 1 行「备份 2025」并在子面板高亮第 2 行
Start-Sleep -Milliseconds 800
CapU "cas-2-cascade" 200 150 1100 700

# 移入子面板第 1 行（freeze 模式不产生高亮，仅验证面板位置与几何）
Go ($subX + 110) ($subY + $headH + [int]($rowH / 2))
Start-Sleep -Milliseconds 500
CapU "cas-3-subrow" 200 150 1100 700

# 右键父面板的文件行（第 3 行之后隔一个分组标签）
Go ($panelX + 150) $fileRowY
Start-Sleep -Milliseconds 300
[void][MouseCtl2]::mouse_event(0x08, 0, 0, 0, [IntPtr]::Zero)   # RIGHTDOWN
[void][MouseCtl2]::mouse_event(0x10, 0, 0, 0, [IntPtr]::Zero)   # RIGHTUP
Start-Sleep -Milliseconds 800
CapU "cas-4-menu" 200 150 1100 700

"--- trace（需先在 FolderDrawer.ahk 里把 CFG.Debug 改成 true）---"
if (Test-Path D:\desk\FolderDrawer\trace.txt) {
    Get-Content D:\desk\FolderDrawer\trace.txt -Encoding UTF8
} else {
    "（无 trace.txt：CFG.Debug 目前是 false）"
}

param([int]$X = 0, [int]$Y = 0, [int]$W = 400, [int]$H = 300, [string]$Name = "cap")
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DpiFix { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
"@
[void][DpiFix]::SetProcessDPIAware()
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap $W, $H
$gr = [System.Drawing.Graphics]::FromImage($bmp)
$gr.CopyFromScreen($X, $Y, 0, 0, (New-Object System.Drawing.Size $W, $H))
$out = "D:\desk\FolderDrawer\dev\shots\$Name-$(Get-Date -Format HHmmss).png"
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$gr.Dispose()
$bmp.Dispose()
$out

/*
  FolderDrawer — 悬停展开桌面文件夹
  ------------------------------------------------------------------
  把鼠标停在【桌面】的文件夹图标上片刻，即弹出该文件夹的内容列表：
    · 悬停文件/文件夹行 → 高亮；单击 = 打开（文件夹在资源管理器中打开）
    · 悬停子文件夹行 → 向右级联展开下一层，可一路深入
    · 右键任意行 → 打开 / 打开文件所在位置 / 复制路径 / 属性
    · 内容超过 MaxRows 行自动限高并可滚动（滚轮）
    · 图标与面板之间的空隙是有效“热区”，配合延迟关闭，鼠标可顺畅滑入
    · 面板不抢焦点（WS_EX_NOACTIVATE），不影响桌面图标的正常点击
  仅对【桌面图标】生效。Esc 或把鼠标移出热区片刻即收起。

  运行：AutoHotkey64.exe FolderDrawer.ahk
  开机自启：Win+R → shell:startup → 把本文件的快捷方式放进去
  调试：Ctrl+Alt+D 在鼠标处弹出示例面板，Ctrl+Alt+Q 退出
*/
#Requires AutoHotkey v2.0+
#SingleInstance Force
DetectHiddenWindows true
Persistent
#Warn All, Off   ; 避免任何警告弹窗阻塞常驻工具

; 运行时错误写入日志而不是弹窗（方便排查，也避免常驻工具被对话框卡死）
OnError(LogError)
LogError(err, mode) {
    try FileAppend(Format("[{}] {} | {} | line {}`n", A_Now, err.Message, err.Extra, err.Line)
        , A_ScriptDir "\error.log", "UTF-8")
    return 1
}

; 统一坐标系：全部使用真实屏幕坐标（与 Win32 API 一致）
CoordMode "Mouse", "Screen"
CoordMode "Pixel", "Screen"
CoordMode "ToolTip", "Screen"
CoordMode "Menu", "Screen"
CoordMode "Caret", "Screen"

; ======================= 可调参数 =======================
global CFG := {
    HoverDelay  : 350,     ; 悬停文件夹多久后展开（毫秒）
    SubDelay    : 320,     ; 悬停弹窗内子文件夹多久后级联展开
    CloseDelay  : 300,     ; 鼠标离开热区多久后收起
    MaxRows     : 12,      ; 面板最大可见行数（超出滚动）
    PanelW      : 300,     ; 面板宽度
    Gap         : 12,      ; 图标与面板的间距
    IconSize    : 22,      ; 列表图标显示尺寸（px）；源图标取 256px 再高质量缩小
    EntranceMs  : 150,     ; 渐显动画时长，0 = 关闭动画
    Shadow      : false,   ; 面板是否带 Windows 投影（false = 无阴影，更干净）
    ShowHidden  : false,   ; 是否显示隐藏文件
    PollMs      : 60,      ; 内部轮询间隔（毫秒）
    Debug       : false    ; true 时写 trace.txt 调试日志
}

; ======================= 全局状态 =======================
global g := {
    hLV         : 0,       ; 桌面 SysListView32 句柄
    rlv         : 0,       ; 跨进程 ListView 访问器
    popups      : [],      ; 打开中的各级面板（Peek 实例）
    rootIdx     : -1,      ; 当前根面板对应的桌面图标索引
    suppressIdx : -1,      ; 被用户主动关掉的图标：鼠标移开它之前不再自动弹出
    pendingIdx  : -1,      ; 正在计时的桌面图标
    pendingTick : 0,
    pendingSub  : "",      ; 正在计时的弹窗内行："层级:行号"
    pendingSubTick : 0,
    leaveTick   : 0,
    paused      : false,
    freeze      : false,   ; 测试模式：不因鼠标离开而关闭
    dirCounts   : Map(),   ; 目录路径 → {n, tick}：“n 项”计数缓存
    countLeft   : 0,       ; 本次面板构造还能枚举多少个未缓存目录（防止几百个子文件夹时卡住）
    fading      : []       ; 正在淡出、待销毁的面板（非阻塞关闭动画）
}

; 主题色（ARGB 供 GDI+，RGB 供 GUI 背景）
global THEME := {}
InitTheme()

; ======================= 启动 =======================
Trace("boot: script started, args=" A_Args.Length)
GpInit()

; 桌面控件可能暂时不可见（资源管理器忙碌/窗口动画中），持续重试直到就绪
StartTool() {
    global g
    g.hLV := InitDesktopListView()
    if !g.hLV
        return false
    try {
        g.rlv := RemoteLV(g.hLV)
    } catch as e {
        Trace("RemoteLV 失败: " e.Message)
        g.hLV := 0
        return false
    }
    SetTimer Watch, CFG.PollMs
    SetTimer StartTool, 0          ; 就绪后停止重试
    TrayTip("已就绪，悬停桌面文件夹试试", "FolderDrawer", 1)
    return true
}

if !StartTool()
    SetTimer StartTool, 600        ; 未就绪则每 0.6 秒重试

HotIf (*) => g.popups.Length > 0
Hotkey "Escape", (*) => CloseAll(true)     ; 用户主动关闭 → 抑制该图标，避免鼠标没动就马上重弹
HotIf

; 滚轮滚动面板内容（仅当鼠标在面板上时生效）
HotIf (*) => PopupAt(CursorX(), CursorY()) != 0
Hotkey "WheelDown", (*) => ScrollPanel(3 * S(11))
Hotkey "WheelUp", (*) => ScrollPanel(-3 * S(11))
HotIf

A_TrayMenu.Delete()
A_TrayMenu.Add("暂停/启用 FolderDrawer", (*) => TogglePause())
A_TrayMenu.Add("重载", (*) => Reload())
A_TrayMenu.Add("退出", (*) => ExitApp())
A_TrayMenu.Default := "暂停/启用 FolderDrawer"

TogglePause() {
    global g
    g.paused := !g.paused
    CloseAll()
    SetTimer Watch, g.paused ? 0 : CFG.PollMs
    TrayTip(g.paused ? "已暂停" : "已启用", "FolderDrawer", 1)
}

; ======================= 主轮询 =======================
Watch() {
    global g, CFG
    if g.freeze                ; 测试模式：主轮询完全停用，便于确定性验证
        return
    if GetKeyState("LButton", "P")     ; 拖拽桌面图标时不触发
        return

    MouseGetPos &mx, &my, &hWin

    ; 桌面控件可能因 explorer 重启而失效：定期校验，失效就重连
    ; （否则会静默失效，而且 SendMessage 失败返回 0 会被当成“命中第 0 个图标”）
    static healthTick := 0
    if (A_TickCount - healthTick > 2000) {
        healthTick := A_TickCount
        if !g.rlv.Alive() {
            Trace("desktop listview 已失效（explorer 重启？），重新初始化")
            CloseAll()
            g.rlv := 0, g.hLV := 0
            SetTimer Watch, 0
            if !StartTool()
                SetTimer StartTool, 600
            return
        }
    }

    ; 心跳：CFG.Debug 时每 2 秒记录一次轮询状态
    static beatTick := 0
    if (CFG.Debug && A_TickCount - beatTick > 2000) {
        beatTick := A_TickCount
        Trace("beat cursor=" mx "," my " desktopWin=" IsDesktopWindow(hWin) " popups=" g.popups.Length)
    }

    ; 悬停期间持续收起系统文件夹提示框（它会盖住面板）
    static tipTick := 0
    if (g.popups.Length && A_TickCount - tipTick > 400) {
        tipTick := A_TickCount
        HideShellTooltips()
    }

    ; 1) 鼠标在某个面板内（或它的热区里）
    if (p := PopupAt(mx, my)) {
        g.leaveTick := 0
        HandlePopupHover(p, mx, my)
        return
    }
    if (g.popups.Length && BridgeAt(mx, my)) {
        g.leaveTick := 0
        g.pendingSub := ""
        return
    }

    ; 2) 鼠标在桌面图标上（必须是真正的桌面窗口，避免被其它窗口遮挡时误触发）
    if IsDesktopWindow(hWin) {
        idx := g.rlv.HitTestScreen(mx, my)
        if idx >= 0 {
            info := DesktopItem(idx)
            if info.isDir {
                ; 这个图标的面板刚被用户主动关掉：鼠标移开之前不再自动弹（否则 Esc 形同无效）
                if (g.suppressIdx = idx) {
                    g.pendingIdx := -1
                    g.leaveTick := 0
                    return
                }
                if (g.suppressIdx >= 0)
                    g.suppressIdx := -1            ; 换到别的图标 → 解除抑制
                if (g.pendingIdx = idx) {
                    if (A_TickCount - g.pendingTick >= CFG.HoverDelay && g.rootIdx != idx)
                        OpenRoot(idx, info)
                } else {
                    g.pendingIdx := idx
                    g.pendingTick := A_TickCount
                }
                g.leaveTick := 0
                return
            }
        }
    }
    if (g.suppressIdx >= 0)
        g.suppressIdx := -1                        ; 鼠标已离开该图标 → 解除抑制
    g.pendingIdx := -1

    ; 3) 鼠标在所有热区之外 → 延迟收起
    if (g.popups.Length && !g.freeze) {
        if !g.leaveTick
            g.leaveTick := A_TickCount
        else if (A_TickCount - g.leaveTick >= CFG.CloseDelay)
            CloseAll()
    }
}

; 鼠标在弹窗行上：高亮 + 必要时级联展开
HandlePopupHover(p, mx, my) {
    global g, CFG
    row := p.HitRow(mx, my)
    if row < 0 {                       ; 在面板留白处：保持
        g.pendingSub := ""
        return
    }
    p.Highlight(row)
    item := p.items[row + 1]
    if item.isDir {
        ; 悬停某个子文件夹一段时间后级联展开；
        ; 斜向穿过其它行时不立即收起已有子面板（与 Windows 级联菜单一致，不闪烁）
        key := p.level ":" row
        if (g.pendingSub != key) {
            g.pendingSub := key
            g.pendingSubTick := A_TickCount
        } else if (A_TickCount - g.pendingSubTick >= CFG.SubDelay) {
            if (g.popups.Length > p.level) {
                if (g.popups[p.level + 1].ownerKey != key)
                    OpenSub(p, row, item)      ; OpenSub 内部会先收起更深层
            } else
                OpenSub(p, row, item)
        }
    } else {
        ; 指向普通项（文件行）时收起下一层：与 Windows 级联菜单一致
        g.pendingSub := ""
        CloseDeeper(p.level)
    }
}

; ======================= 面板开关 =======================
OpenRoot(idx, info) {
    global g
    Trace("OpenRoot idx=" idx " target=" info.target)
    HideShellTooltips()
    CloseAll(false, false)                     ; 马上要开新面板：旧面板立即销毁，不淡出
    rect := g.rlv.ItemRectScreen(idx, 1)        ; LVIR_ICON
    p := Peek(1, info.target, rect, "")
    g.popups := [p]
    g.rootIdx := idx
    p.Show()
}

OpenSub(parent, row, item) {
    global g
    CloseDeeper(parent.level, false)   ; 换成新的一层：旧层立即让位，不做淡出（避免与新面板重叠）
    anchor := parent.RowRectScreen(row)
    p := Peek(parent.level + 1, item.target, anchor, parent.level ":" row)
    g.popups.Push(p)
    p.Show()
}

; 收起比 level 更深的层。animate=true（默认）时先淡出再销毁，效果与整体关闭一致。
CloseDeeper(level, animate := true) {
    global g
    if (g.popups.Length <= level)
        return
    list := []
    while (g.popups.Length > level)
        list.Push(g.popups.Pop())
    if animate
        FadeOutPanels(list)
    else
        for p in list
            p.Destroy()
}

; 让一组面板“淡出 + 轻微下滑”（与进场“渐显 + 上滑”对称），淡完自动销毁。
; 非阻塞：用 15ms 的全局定时器推进，多批可同时在飞，主轮询不受影响。
FadeOutPanels(list) {
    global g, CFG
    if !list.Length
        return
    if (CFG.EntranceMs <= 0 || g.freeze) {
        for p in list
            p.Destroy()
        return
    }
    now := A_TickCount
    dur := Max(60, CFG.EntranceMs // 2)
    for p in list
        g.fading.Push({p: p, start: now, dur: dur})
    SetTimer(FadeTick, 15)
}

FadeTick() {
    global g
    now := A_TickCount
    still := []
    for f in g.fading {
        p := f.p
        if p.destroyed
            continue
        t := (now - f.start) / f.dur
        if (t >= 1) {
            p.Destroy()                                      ; 淡完了才真正销毁
            continue
        }
        try WinSetTransparent(Max(1, Round(255 * (1 - t))), "ahk_id " p.gui.Hwnd)
        DllCall("SetWindowPos", "ptr", p.gui.Hwnd, "ptr", 0
            , "int", p.x, "int", p.y + Round(S(4) * t)
            , "int", 0, "int", 0, "uint", 0x0011)            ; NOACTIVATE|NOSIZE（允许移动）
        still.Push(f)
    }
    g.fading := still
    if !still.Length
        SetTimer(FadeTick, 0)
}

CloseAll(suppress := false, animate := true) {
    global g, CFG
    if g.popups.Length
        Trace("CloseAll (had " g.popups.Length " panel(s))")
    if animate
        FadeOutPanels(g.popups)          ; 淡出 + 下滑，约 75ms 后自行销毁（不阻塞轮询）
    else
        for p in g.popups
            p.Destroy()
    g.popups := []
    ; 用户主动关闭（Esc / 单击打开 / 右键菜单）时记住来源图标：鼠标还停在它上面就先不自动弹。
    ; 必须在清 rootIdx 之前取，等鼠标移开（或悬停别的图标）时解除。
    if (suppress && g.rootIdx >= 0)
        g.suppressIdx := g.rootIdx
    g.rootIdx := -1
    g.pendingSub := ""
    g.leaveTick := 0
}

; 鼠标是否落在某个面板上（从最上层往下找：面板在屏幕边缘会翻到父面板左侧而互相重叠）
PopupAt(mx, my) {
    global g
    i := g.popups.Length
    while (i >= 1) {
        p := g.popups[i]
        if (mx >= p.x && mx < p.x + p.w && my >= p.y && my < p.y + p.h)
            return p
        i -= 1
    }
    return 0
}

; 图标↔面板之间的“桥接”热区，保证鼠标滑入面板不断开
BridgeAt(mx, my) {
    global g
    for p in g.popups {
        a := p.anchor
        if (mx >= a.left && mx <= a.right && my >= a.top && my <= a.bottom)
            return true
        ; 图标与面板之间的水平走廊（含 4px 容差）
        ; 这里不能用“两者的外接矩形”：那样图标周围一整片桌面都会变成热区，
        ; 落在里面的其它图标既不会弹新面板、也不会收旧面板
        cL := Min(a.right, p.x + p.w), cR := Max(a.left, p.x)
        if (mx >= cL - S(4) && mx <= cR + S(4)
            && ((my >= a.top - S(4) && my <= a.bottom + S(4))
                || (my >= p.y && my <= p.y + p.h)))
            return true
    }
    return false
}

ScrollPanel(delta) {
    global g
    if !g.popups.Length
        return
    p := PopupAt(CursorX(), CursorY())
    if !p
        p := g.popups[g.popups.Length]
    p.ScrollBy(delta)
}

; ======================= 弹窗面板（GDI+ 自绘） =======================
class Peek {
    __New(level, path, anchorRect, ownerKey) {
        global CFG, THEME
        this.level := level
        this.path := path
        this.ownerKey := ownerKey
        this.anchor := {left: anchorRect.left, top: anchorRect.top
            , right: anchorRect.right, bottom: anchorRect.bottom}
        this.items := LoadDir(path)
        Trace("Peek.New level=" level " path=" path " items=" this.items.Length)
        this.hover := -1
        this.scrollY := 0
        this.hBmp := 0             ; 复用的 32bpp 位图（每帧新建会持续泄漏 GDI 对象）
        this.bmpW := 0, this.bmpH := 0
        this.destroyed := false
        this.animStart := 0
        this.animFn := ObjBindMethod(this, "AnimTick")   ; 进场动画的逐帧回调（复用同一个函数对象）

        ; ---- 版式度量（px，随 DPI 缩放）----
        this.w      := S(CFG.PanelW)
        this.rowH   := S(32)
        this.padX   := S(10)
        this.headH  := S(46)
        this.footH  := S(30)
        this.labelH := S(24)

        ; ---- 行布局：分组标签 + 行 ----
        this.rows := []            ; {index, y, h, item}
        this.blocks := []          ; {kind:"label"/"row", y, h, ...}
        this.BuildLayout()
        maxH := CFG.MaxRows * this.rowH + 2 * this.labelH
        this.viewH := Min(this.contentH, maxH)
        if (this.viewH < S(32))
            this.viewH := S(32)
        this.h := this.headH + this.viewH + this.footH

        ; ---- 窗口 ----
        this.gui := Gui("+ToolWindow -Caption +AlwaysOnTop +E0x08000000", "FolderDrawer") ; WS_EX_NOACTIVATE
        this.gui.MarginX := 0, this.gui.MarginY := 0
        this.gui.BackColor := THEME.BGRGB
        ; SS_NOTIFY(0x100) | SS_BITMAP(0x0E)：显式指定，否则控件不渲染位图、也不响应点击
        this.pic := this.gui.AddPic("x0 y0 w" this.w " h" this.h " +0x10E")
        this.pic.OnEvent("Click", ObjBindMethod(this, "OnPicClick"))
        this.pic.OnEvent("ContextMenu", ObjBindMethod(this, "OnPicMenu"))

        ; 文件夹图标缓存
        this.icons := Map()
    }

    ; 分组标签 + 行的纵向布局
    BuildLayout() {
        this.rows := [], this.blocks := []
        if (this.items.Length = 0) {
            this.contentH := this.rowH
            return
        }
        ; 按 文件夹/文件 分组（LoadDir 已排好序，分组必连续）
        groups := []
        cur := ""
        for it in this.items {
            kind := it.isDir ? "d" : "f"
            if (kind != cur) {
                cur := kind
                groups.Push({kind: kind, items: []})
            }
            groups[groups.Length].items.Push(it)
        }
        y := 0, idx := 0
        for grp in groups {
            if (groups.Length > 1) {
                this.blocks.Push({kind: "label", y: y, h: this.labelH
                    , text: grp.kind = "d" ? "文件夹" : "文件"})
                y += this.labelH
            }
            for it in grp.items {
                this.rows.Push({index: idx, y: y, h: this.rowH, item: it})
                this.blocks.Push({kind: "row", y: y, h: this.rowH, idx: idx})
                y += this.rowH
                idx += 1
            }
        }
        this.contentH := y
    }

    Show() {
        global CFG, THEME
        ; 位置：默认在锚点右侧，越界翻到左侧 / 屏内钳制
        a := this.anchor
        x := a.right + S(CFG.Gap)
        y := a.top - S(8)
        wa := WorkAreaAt(a.left, a.top)
        if (x + this.w > wa.right - S(8))
            x := a.left - this.w - S(CFG.Gap)      ; 右侧放不下 → 翻到左侧
        if (x < wa.left + S(8))
            x := wa.left + S(8)
        if (y + this.h > wa.bottom - S(8))
            y := Max(wa.top + S(8), wa.bottom - this.h - S(8))
        if (y < wa.top + S(8))
            y := wa.top + S(8)
        this.x := x, this.y := y

        Trace("Peek.Show level=" this.level " pos=" x "," y " size=" this.w "x" this.h)
        ; 在“显示之前”就设成几乎全透明：否则窗口会先以完全不透明画出一帧，
        ; 15ms 后才被第一帧动画压暗 —— 看起来就是“打开时闪一下”
        if (CFG.EntranceMs > 0)
            try WinSetTransparent(1, "ahk_id " this.gui.Hwnd)
        this.gui.Show("NA x" x " y" y " w" this.w " h" this.h)
        ApplyRoundedCorners(this.gui.Hwnd)
        this.Paint()
        this.FadeIn()
    }

    ; ---------- 绘制 ----------
    Paint() {
        global THEME, CFG
        w := this.w, h := this.h
        hwnd := this.gui.Hwnd
        hdc := DllCall("GetDC", "ptr", hwnd, "ptr")
        memDC := DllCall("CreateCompatibleDC", "ptr", hdc, "ptr")
        ; 位图只建一次并复用：每帧新建 DIB + STM_SETIMAGE 会持续泄漏 GDI 对象
        ; （实测每帧 +1，一天几百次悬停就是几百个对象），而且每帧还要分配约 600KB。
        ; 只有面板尺寸变化时才重建。
        if (!this.hBmp || this.bmpW != w || this.bmpH != h) {
            if this.hBmp
                DllCall("DeleteObject", "ptr", this.hBmp)
            bi := Buffer(40, 0)
            NumPut("uint", 40, bi, 0), NumPut("int", w, bi, 4), NumPut("int", -h, bi, 8)
            NumPut("ushort", 1, bi, 12), NumPut("ushort", 32, bi, 14)
            this.hBmp := DllCall("CreateDIBSection", "ptr", memDC, "ptr", bi, "uint", 0
                , "ptr*", &bits := 0, "ptr", 0, "uint", 0, "ptr")
            this.bmpW := w, this.bmpH := h
            prev := DllCall("SendMessageW", "ptr", this.pic.Hwnd, "uint", 0x0172, "ptr", 0, "ptr", this.hBmp, "ptr") ; STM_SETIMAGE
            if prev
                DllCall("DeleteObject", "ptr", prev)
        }
        old := DllCall("SelectObject", "ptr", memDC, "ptr", this.hBmp, "ptr")
        gp := GpFromHDC(memDC)
        ; 底色铺满整块位图：圆角外的透明像素会被当成黑色，必须先铺满
        GpFillRect(gp, 0, 0, w, h, THEME.BG)
        GpFillRound(gp, 1, 1, w - 2, h - 2, S(11), THEME.BG)
        GpStrokeRound(gp, 1, 1, w - 2, h - 2, S(11), THEME.LINE, 1)

        ; 标题 + 计数徽标
        name := FolderName(this.path)
        GpText(gp, name, S(16), S(4), w - S(120), this.headH - S(8), 9.6, THEME.FG, true, 0, 1)
        pillW := S(52), pillH := S(20)
        GpFillRound(gp, w - pillW - S(16), (this.headH - pillH) / 2, pillW, pillH, pillH / 2, THEME.PILL)
        GpText(gp, this.items.Length " 项", w - pillW - S(16), (this.headH - pillH) / 2, pillW, pillH, 7.8, THEME.SUB, false, 1, 1)

        ; 内容（裁剪到可视区）
        GpClip(gp, 0, this.headH, w, this.viewH)
        yBase := this.headH
        for b in this.blocks {
            by := yBase + b.y - this.scrollY
            if (by + b.h < yBase - 2 || by > yBase + this.viewH + 2)
                continue
            if (b.kind = "label") {
                GpText(gp, b.text, S(18), by, w - S(36), b.h, 7.8, THEME.SUB2, false, 0, 1)
                continue
            }
            it := this.rows[b.idx + 1].item
            if (b.idx = this.hover)
                GpFillRound(gp, this.padX, by + S(2), w - this.padX * 2, b.h - S(4), S(8), THEME.HOVER)
            img := this.IconOf(it)
            if img
                GpIcon(gp, img, S(16), by + (b.h - S(CFG.IconSize)) / 2, S(CFG.IconSize))
            GpText(gp, it.name, S(46), by, w - S(120), b.h, 9.2, it.isDir ? THEME.FG : THEME.FG2, false, 0, 1)
            if it.isDir {
                GpText(gp, it.sub, w - S(68), by, S(38), b.h, 7.8, THEME.SUB, false, 2, 1)
                GpText(gp, "›", w - S(32), by - S(1), S(16), b.h, 11, THEME.SUB, false, 1, 1)
            } else {
                GpText(gp, it.sub, w - S(140), by, S(124), b.h, 7.8, THEME.SUB, false, 2, 1)
            }
        }
        GpUnclip(gp)

        ; 滚动条
        if (this.contentH > this.viewH + 2) {
            trackH := this.viewH - S(8)
            thumbH := Max(S(24), trackH * this.viewH / this.contentH)
            maxScroll := this.contentH - this.viewH
            thumbY := this.headH + S(4) + (trackH - thumbH) * (maxScroll ? this.scrollY / maxScroll : 0)
            GpFillRound(gp, w - S(7), thumbY, S(3), thumbH, S(2), THEME.SCRUB)
        }

        ; 页脚
        GpLine(gp, S(14), h - this.footH, w - S(14), h - this.footH, THEME.LINE, 1)
        GpText(gp, "单击打开 · 右键更多 · 滚轮滚动", S(16), h - this.footH, w - S(32), this.footH, 7.8, THEME.SUB2, false, 0, 1)
        DllCall("gdiplus\GdipDeleteGraphics", "ptr", gp)
        DllCall("SelectObject", "ptr", memDC, "ptr", old)
        DllCall("DeleteDC", "ptr", memDC)
        DllCall("ReleaseDC", "ptr", hwnd, "ptr", hdc)

        ; 强制控件用新位图重绘（否则偶发显示空白）
        DllCall("InvalidateRect", "ptr", this.pic.Hwnd, "ptr", 0, "int", 1)
        DllCall("UpdateWindow", "ptr", this.pic.Hwnd)
        if CFG.Debug
            try FileAppend(Format("paint level={} bg={:X} fg={:X} rows={} hover={}`n"
                , this.level, THEME.BG, THEME.FG, this.rows.Length, this.hover), A_ScriptDir "\error.log", "UTF-8")
    }

    IconOf(it) {
        global CFG
        if this.icons.Has(it.path)
            return this.icons[it.path]        ; 缓存：已缩放到显示尺寸的 GpBitmap
        img := LoadIconBitmap(it.path, S(CFG.IconSize))
        this.icons[it.path] := img
        return img
    }

    ; ---------- 交互 ----------
    OnPicClick(ctrl, info) {
        row := this.HitRow(CursorX(), CursorY())
        if (row >= 0)
            DoOpen(this.items[row + 1])
    }

    OnPicMenu(ctrl, item, isRight, x, y) {
        row := this.HitRow(CursorX(), CursorY())
        if (row >= 0)
            ShowRowMenu(this.items[row + 1])
    }

    ScrollBy(delta) {
        maxScroll := Max(0, this.contentH - this.viewH)
        ny := this.scrollY + delta
        ny := Max(0, Min(maxScroll, ny))
        if (ny != this.scrollY) {
            this.scrollY := ny
            this.Paint()
        }
    }

    HitRow(mx, my) {
        if (mx < this.x || mx >= this.x + this.w)
            return -1
        ly := my - (this.y + this.headH) + this.scrollY
        if (ly < 0 || ly > this.viewH)
            return -1
        for b in this.blocks {
            if (b.kind != "row")
                continue
            if (ly >= b.y && ly < b.y + b.h)
                return b.idx
        }
        return -1
    }

    RowRectScreen(i) {
        for b in this.blocks {
            if (b.kind = "row" && b.idx = i) {
                top := this.y + this.headH + b.y - this.scrollY
                return {left: this.x + this.padX, top: top
                    , right: this.x + this.w - this.padX, bottom: top + b.h}
            }
        }
        return {left: this.x, top: this.y + this.headH
            , right: this.x + this.w, bottom: this.y + this.headH + this.rowH}
    }

    Highlight(row) {
        if (this.hover = row)
            return
        this.hover := row
        this.Paint()
    }

    ; 渐显 + 轻微上滑；分层窗口（WS_EX_LAYERED）不带 DWM 阴影。
    ; 用 SetTimer 逐帧推进而不是 Sleep：不再阻塞主轮询（原来 150ms 里悬停高亮、关闭都得排队），
    ; 而且帧数由时间驱动，比固定 5 步顺滑得多。
    FadeIn() {
        global CFG
        if (CFG.EntranceMs <= 0) {
            this.AnimEnd()
            return
        }
        this.animStart := A_TickCount
        SetTimer(this.animFn, 15)
    }

    AnimTick() {
        global CFG
        if this.destroyed
            return
        t := (A_TickCount - this.animStart) / CFG.EntranceMs
        if (t >= 1) {
            SetTimer(this.animFn, 0)
            this.AnimEnd()
            return
        }
        try WinSetTransparent(Max(1, Round(255 * t)), "ahk_id " this.gui.Hwnd)
        DllCall("SetWindowPos", "ptr", this.gui.Hwnd, "ptr", 0
            , "int", this.x, "int", this.y + Round(S(6) * (1 - t))
            , "int", 0, "int", 0, "uint", 0x0011)              ; NOACTIVATE|NOSIZE（允许移动）
    }

    ; 动画收尾：无阴影 → 保持分层（alpha=255 不透明、不带 DWM 投影）；有阴影 → 取消分层恢复 DWM 阴影
    AnimEnd() {
        global CFG
        if this.destroyed
            return
        try WinSetTransparent(CFG.Shadow ? "Off" : 255, "ahk_id " this.gui.Hwnd)
        DllCall("SetWindowPos", "ptr", this.gui.Hwnd, "ptr", 0
            , "int", this.x, "int", this.y, "int", 0, "int", 0, "uint", 0x0015) ; NOACTIVATE|NOSIZE|NOMOVE
    }

    Destroy() {
        this.destroyed := true
        try SetTimer(this.animFn, 0)              ; 停掉还没跑完的进场动画
        ; 释放面板位图：先把它从控件上换下来（控件销毁不会释放它），再删除
        if this.hBmp {
            try {
                DllCall("SendMessageW", "ptr", this.pic.Hwnd, "uint", 0x0172, "ptr", 0, "ptr", 0, "ptr") ; STM_SETIMAGE(NULL)
                DllCall("DeleteObject", "ptr", this.hBmp)
            }
            this.hBmp := 0
        }
        for k, img in this.icons
            if img
                try DllCall("gdiplus\GdipDisposeImage", "ptr", img)
        try this.gui.Destroy()
    }
}

; ======================= 行操作 =======================
DoOpen(item) {
    CloseAll(true)          ; 用户主动打开 → 抑制来源图标，避免鼠标没动就立刻重弹
    if item.isDir
        Run('explorer.exe "' item.target '"')
    else
        Run('"' item.target '"')
}

ShowRowMenu(item) {
    m := Menu()
    m.Add("打开", (*) => DoOpen(item))
    m.Add("打开文件所在位置", (*) => (CloseAll(true), Run('explorer.exe /select,"' item.path '"')))
    m.Add("复制路径", (*) => (A_Clipboard := item.path, TrayTip("已复制路径", "FolderDrawer", 1)))
    m.Add()
    m.Add("属性", (*) => (CloseAll(true), ShowProperties(item.path)))
    m.Show()      ; 不传坐标 → 跟随鼠标，避开坐标系差异
}

ShowProperties(path) {
    size := A_PtrSize = 8 ? 112 : 60
    sei := Buffer(size, 0)
    NumPut("uint", size, sei, 0)                                  ; cbSize
    NumPut("uint", 0x0C, sei, 4)                                  ; fMask = SEE_MASK_INVOKEIDLIST
    NumPut("ptr", 0, sei, 8)                                      ; hwnd
    NumPut("ptr", StrPtr("properties"), sei, 8 + A_PtrSize)       ; lpVerb
    NumPut("ptr", StrPtr(path), sei, 8 + A_PtrSize * 2)           ; lpFile
    NumPut("ptr", 0, sei, 8 + A_PtrSize * 3)                      ; lpParameters
    NumPut("ptr", 0, sei, 8 + A_PtrSize * 4)                      ; lpDirectory
    NumPut("int", 1, sei, 8 + A_PtrSize * 5)                      ; nShow = SW_SHOWNORMAL
    DllCall("shell32\ShellExecuteExW", "ptr", sei)
}

; ======================= 桌面条目 =======================
DesktopItem(idx) {
    global g
    name := g.rlv.ItemText(idx)
    path := ResolveDesktopPath(name)
    target := ResolveTarget(path)
    isDir := InStr(FileExist(target), "D") ? true : false
    return {name: name, path: path, target: target, isDir: isDir}
}

ResolveDesktopPath(name) {
    for base in [A_Desktop, A_DesktopCommon] {
        for cand in [base "\" name, base "\" name ".lnk", base "\" name ".url"] {
            if FileExist(cand)
                return cand
        }
    }
    return A_Desktop "\" name
}

ResolveTarget(path) {
    if RegExMatch(path, "i)\.(lnk|url)$") {
        try {
            FileGetShortcut path, &tgt
            if (tgt != "")
                return tgt
        }
    }
    return path
}

; 该项是否不显示（列目录与“n 项”计数共用同一套规则，避免两者对不上）
SkipItem(name, attrib) {
    global CFG
    if (name = "desktop.ini")
        return true
    ; Loop Files 没有 H 选项、且默认就会列出隐藏项，只能在属性上过滤
    if (!CFG.ShowHidden && InStr(attrib, "H"))
        return true
    return false
}

; 载入一个文件夹：文件夹在前、文件在后，各按名称排序
LoadDir(path) {
    global CFG, g
    g.countLeft := 40          ; 本次面板构造最多枚举 40 个未缓存子目录，其余先显示“…”
    dirs := [], files := []
    try {
        Loop Files path "\*", "DF" {
            n := A_LoopFileName
            if SkipItem(n, A_LoopFileAttrib)
                continue
            isDir := InStr(A_LoopFileAttrib, "D") ? true : false
            it := MakeItem(n, A_LoopFileFullPath, isDir)
            if it.isDir
                dirs.Push(it)
            else
                files.Push(it)
        }
    }
    SortItems(dirs), SortItems(files)
    out := []
    for it in dirs
        out.Push(it)
    for it in files
        out.Push(it)
    return out
}

MakeItem(name, path, isDir) {
    target := ResolveTarget(path)
    ; 指向文件夹的快捷方式按文件夹处理（可级联展开）
    if (!isDir && InStr(FileExist(target), "D"))
        isDir := true
    if isDir {
        n := DirCount(target)      ; 带缓存 + 配额，避免“几百个子文件夹”时卡住
        return {name: name, path: path, target: target, isDir: true, sub: n >= 0 ? n " 项" : "…"}
    }
    size := 0
    try size := FileGetSize(path)
    return {name: name, path: path, target: target, isDir: false, sub: GetTypeName(path) " · " FmtSize(size)}
}

; 子文件夹的“n 项”：结果缓存 60 秒（同一文件夹反复悬停不再重复枚举）；
; 单次面板构造里最多枚举 g.countLeft 个未缓存目录，超出的先返回 -1（显示“…”）。
DirCount(path) {
    global g
    c := g.dirCounts.Get(path, 0)
    if (c && A_TickCount - c.tick < 60000)
        return c.n
    if (g.countLeft <= 0)
        return -1
    g.countLeft -= 1
    n := 0
    try {
        Loop Files path "\*", "DF" {
            if SkipItem(A_LoopFileName, A_LoopFileAttrib)
                continue
            n += 1
        }
    }
    g.dirCounts[path] := {n: n, tick: A_TickCount}
    return n
}

SortItems(arr) {                    ; 归并排序 O(n log n)：插入排序在上万项时会明显卡顿
    n := arr.Length
    if (n < 2)
        return
    tmp := []
    tmp.Length := n
    MergeSortNames(arr, tmp, 1, n)
}

MergeSortNames(a, t, lo, hi) {      ; 稳定排序，比较规则与旧插入排序一致（名称不区分大小写）
    if (lo >= hi)
        return
    mid := (lo + hi) // 2
    MergeSortNames(a, t, lo, mid)
    MergeSortNames(a, t, mid + 1, hi)
    i := lo, j := mid + 1, k := lo
    while (i <= mid && j <= hi) {
        if (StrCompare(a[i].name, a[j].name, false) <= 0)
            t[k] := a[i], i += 1
        else
            t[k] := a[j], j += 1
        k += 1
    }
    while (i <= mid)
        t[k] := a[i], i += 1, k += 1
    while (j <= hi)
        t[k] := a[j], j += 1, k += 1
    k := lo
    while (k <= hi)
        a[k] := t[k], k += 1
}

; ======================= 桌面 ListView（跨进程访问） =======================
InitDesktopListView() {
    DetectHiddenWindows true
    hLV := 0
    hProg := WinExist("ahk_class Progman")
    if hProg
        try hLV := ControlGetHwnd("SysListView321", "ahk_id " hProg)
    if !hLV {
        hW := 0
        loop {
            hW := DllCall("FindWindowExW", "ptr", 0, "ptr", hW, "str", "WorkerW", "ptr", 0, "ptr")
            if !hW
                break
            try {
                hLV := ControlGetHwnd("SysListView321", "ahk_id " hW)
                if hLV
                    break
            }
        }
    }
    return hLV
}

; 桌面图标列表属于 explorer.exe，缓冲区必须分配在对方进程里
class RemoteLV {
    __New(hLV) {
        this.hLV := hLV
        DllCall("GetWindowThreadProcessId", "ptr", hLV, "uint*", &pid := 0)
        this.pid := pid
        this.hProc := DllCall("OpenProcess", "uint", 0x38, "int", 0, "uint", pid, "ptr")
        if !this.hProc
            throw Error("无法打开 explorer 进程")
        this.mem := DllCall("VirtualAllocEx", "ptr", this.hProc, "ptr", 0, "uptr", 4096, "uint", 0x3000, "uint", 4, "ptr")
        if !this.mem
            throw Error("无法在 explorer 进程分配内存")
    }

    ; explorer 重启后旧句柄会失效（甚至被系统复用给别的窗口），所以要连进程号一起校验
    Alive() {
        if (!this.hLV || !this.hProc)
            return false
        DllCall("GetWindowThreadProcessId", "ptr", this.hLV, "uint*", &pid := 0)
        return (pid = this.pid)
    }

    __Delete() {
        if this.mem
            try DllCall("VirtualFreeEx", "ptr", this.hProc, "ptr", this.mem, "uptr", 0, "uint", 0x8000)   ; MEM_RELEASE
        if this.hProc
            try DllCall("CloseHandle", "ptr", this.hProc)
        this.mem := 0, this.hProc := 0
    }

    Write(buf) => DllCall("WriteProcessMemory", "ptr", this.hProc, "ptr", this.mem
        , "ptr", buf.Ptr, "uptr", buf.Size, "uptr*", 0)

    Read(size, off := 0) {
        out := Buffer(size)
        DllCall("ReadProcessMemory", "ptr", this.hProc, "ptr", this.mem + off
            , "ptr", out.Ptr, "uptr", size, "uptr*", 0)
        return out
    }

    ; 图标总数
    ItemCount() => DllCall("SendMessageW", "ptr", this.hLV, "uint", 0x1004, "ptr", 0, "ptr", 0, "ptr")

    ; 命中检测：返回桌面图标索引，-1 = 未命中
    HitTestScreen(sx, sy) {
        if !this.Alive()      ; 句柄失效时 SendMessage 会返回 0，不能当成“命中第 0 个图标”
            return -1
        pt := Buffer(8, 0)
        NumPut("int", sx, pt, 0), NumPut("int", sy, pt, 4)
        DllCall("ScreenToClient", "ptr", this.hLV, "ptr", pt)
        hti := Buffer(32, 0)                                  ; LVHITTESTINFO
        NumPut("int", NumGet(pt, 0, "int"), hti, 0)
        NumPut("int", NumGet(pt, 4, "int"), hti, 4)
        this.Write(hti)
        return DllCall("SendMessageW", "ptr", this.hLV, "uint", 0x1012, "ptr", 0, "ptr", this.mem, "ptr")
    }

    ; 图标矩形（屏幕坐标）；code: 0=整体 1=图标 2=文字
    ItemRectScreen(idx, code := 0) {
        r := Buffer(16, 0)
        NumPut("int", code, r, 0)
        this.Write(r)
        DllCall("SendMessageW", "ptr", this.hLV, "uint", 0x100E, "ptr", idx, "ptr", this.mem)
        out := this.Read(16)
        x1 := NumGet(out, 0, "int"), y1 := NumGet(out, 4, "int")
        x2 := NumGet(out, 8, "int"), y2 := NumGet(out, 12, "int")
        pt := Buffer(8, 0)
        NumPut("int", x1, pt, 0), NumPut("int", y1, pt, 4)
        DllCall("ClientToScreen", "ptr", this.hLV, "ptr", pt)
        sx := NumGet(pt, 0, "int"), sy := NumGet(pt, 4, "int")
        return {left: sx, top: sy, right: sx + (x2 - x1), bottom: sy + (y2 - y1)}
    }

    ; 图标显示文本（LVM_GETITEMTEXTW = 0x1073，实测该消息返回 UTF-16 文本）
    ItemText(idx) {
        pszOff := A_PtrSize = 8 ? 24 : 20
        lvi := Buffer(64, 0)
        NumPut("uint", 1, lvi, 0)                            ; LVIF_TEXT
        NumPut("int", idx, lvi, 4)
        NumPut("int", 0, lvi, 8)                             ; iSubItem
        NumPut("ptr", this.mem + 256, lvi, pszOff)           ; pszText → 远程缓冲区偏移 256
        NumPut("int", 128, lvi, pszOff + A_PtrSize)          ; cchTextMax
        this.Write(lvi)
        DllCall("SendMessageW", "ptr", this.hLV, "uint", 0x1073, "ptr", idx, "ptr", this.mem)
        txt := this.Read(256, 256)
        return StrGet(txt, 128, "UTF-16")
    }
}

; ======================= GDI+ 绘制 =======================
GpInit() {
    static token := 0          ; 函数内静态变量：不受全局初始化顺序影响
    if token
        return
    si := Buffer(24, 0)
    NumPut("uint", 1, si, 0)                                 ; GdiplusVersion = 1
    DllCall("gdiplus\GdiplusStartup", "ptr*", &t := 0, "ptr", si, "ptr", 0)
    token := t
}

GpFromHDC(hdc) {
    DllCall("gdiplus\GdipCreateFromHDC", "ptr", hdc, "ptr*", &g := 0)
    DllCall("gdiplus\GdipSetSmoothingMode", "ptr", g, "int", 2)          ; AntiAlias
    DllCall("gdiplus\GdipSetPixelOffsetMode", "ptr", g, "int", 2)        ; HighQuality
    DllCall("gdiplus\GdipSetTextRenderingHint", "ptr", g, "int", 3)     ; AntiAliasGridFit：文字比纯 AntiAlias 锐利
    DllCall("gdiplus\GdipSetInterpolationMode", "ptr", g, "int", 7)     ; HighQualityBicubic
    return g
}

GpSolid(argb) {
    DllCall("gdiplus\GdipCreateSolidFill", "uint", argb, "ptr*", &b := 0)
    return b
}

GpFillRound(gp, x, y, w, h, r, argb) {
    if (r <= 0) {
        GpFillRect(gp, x, y, w, h, argb)
        return
    }
    r := Min(r, w / 2, h / 2)
    p := GpPath()
    d := r * 2
    DllCall("gdiplus\GdipAddPathArc", "ptr", p, "float", x, "float", y, "float", d, "float", d, "float", 180, "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", p, "float", x + w - d, "float", y, "float", d, "float", d, "float", 270, "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", p, "float", x + w - d, "float", y + h - d, "float", d, "float", d, "float", 0, "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", p, "float", x, "float", y + h - d, "float", d, "float", d, "float", 90, "float", 90)
    DllCall("gdiplus\GdipClosePathFigures", "ptr", p)
    b := GpSolid(argb)
    DllCall("gdiplus\GdipFillPath", "ptr", gp, "ptr", b, "ptr", p)
    DllCall("gdiplus\GdipDeleteBrush", "ptr", b)
    DllCall("gdiplus\GdipDeletePath", "ptr", p)
}

GpStrokeRound(gp, x, y, w, h, r, argb, width := 1) {
    if (r <= 0)
        return
    r := Min(r, w / 2, h / 2)
    p := GpPath()
    d := r * 2
    DllCall("gdiplus\GdipAddPathArc", "ptr", p, "float", x, "float", y, "float", d, "float", d, "float", 180, "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", p, "float", x + w - d, "float", y, "float", d, "float", d, "float", 270, "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", p, "float", x + w - d, "float", y + h - d, "float", d, "float", d, "float", 0, "float", 90)
    DllCall("gdiplus\GdipAddPathArc", "ptr", p, "float", x, "float", y + h - d, "float", d, "float", d, "float", 90, "float", 90)
    DllCall("gdiplus\GdipClosePathFigures", "ptr", p)
    DllCall("gdiplus\GdipCreatePen1", "uint", argb, "float", width, "int", 2, "ptr*", &pen := 0)
    DllCall("gdiplus\GdipDrawPath", "ptr", gp, "ptr", pen, "ptr", p)
    DllCall("gdiplus\GdipDeletePen", "ptr", pen)
    DllCall("gdiplus\GdipDeletePath", "ptr", p)
}

GpFillRect(gp, x, y, w, h, argb) {
    b := GpSolid(argb)
    DllCall("gdiplus\GdipFillRectangle", "ptr", gp, "ptr", b, "float", x, "float", y, "float", w, "float", h)
    DllCall("gdiplus\GdipDeleteBrush", "ptr", b)
}

GpLine(gp, x1, y1, x2, y2, argb, width := 1) {
    DllCall("gdiplus\GdipCreatePen1", "uint", argb, "float", width, "int", 2, "ptr*", &pen := 0)
    DllCall("gdiplus\GdipDrawLine", "ptr", gp, "ptr", pen, "float", x1, "float", y1, "float", x2, "float", y2)
    DllCall("gdiplus\GdipDeletePen", "ptr", pen)
}

; 文本：pt=字号(点)，align 0=左 1=中 2=右，lineAlign 垂直对齐同上。
; 字体族与各字号的 Font 只建一次并缓存（原来每次调用都新建/销毁，一帧就是几十次）
GpText(gp, text, x, y, w, h, pt, argb, bold := false, align := 0, lineAlign := 1) {
    if (text = "")
        return
    x := Round(x), y := Round(y)          ; 对齐到整像素：非整坐标会让文字发虚
    static fam := 0, fonts := Map()
    if !fam
        DllCall("gdiplus\GdipCreateFontFamilyFromName", "str", "Segoe UI", "ptr", 0, "ptr*", &fam := 0)
    key := pt "|" (bold ? 1 : 0)
    font := fonts.Get(key, 0)
    if !font {
        DllCall("gdiplus\GdipCreateFont", "ptr", fam, "float", pt, "int", bold ? 1 : 0, "int", 3, "ptr*", &f := 0)
        if !f
            return
        fonts[key] := f
        font := f
    }
    b := GpSolid(argb)
    DllCall("gdiplus\GdipCreateStringFormat", "int", 0x1000, "int", 0, "ptr*", &fmt := 0)  ; NoWrap
    DllCall("gdiplus\GdipSetStringFormatAlign", "ptr", fmt, "int", align)
    DllCall("gdiplus\GdipSetStringFormatLineAlign", "ptr", fmt, "int", lineAlign)
    rc := Buffer(16, 0)
    NumPut("float", x, rc, 0), NumPut("float", y, rc, 4), NumPut("float", w, rc, 8), NumPut("float", h, rc, 12)
    DllCall("gdiplus\GdipDrawString", "ptr", gp, "str", text, "int", -1, "ptr", font, "ptr", rc, "ptr", fmt, "ptr", b)
    DllCall("gdiplus\GdipDeleteStringFormat", "ptr", fmt)
    DllCall("gdiplus\GdipDeleteBrush", "ptr", b)
}

; 取图标的 HICON：优先 48×48（SHIL_EXTRALARGE），没拿到再试 256×256（SHIL_JUMBO），
; 最后退回 SHGetFileInfo 的 32×32。
; 注意不要优先用 256：不少应用的 256px 图标是“白底 + 小 logo”，缩到 20 来 px 后整片纯白，
; 在浅色面板上等于看不见（实测 Games 里的 RWC / SakuraFrp 就会这样消失）。
IconHandle(path) {
    static lists := 0, fnGetIcon := 0
    if !lists {
        iid := Buffer(16, 0)                        ; IID_IImageList {46EB5926-582E-4017-9FDF-E8998DAA0950}
        NumPut("uint", 0x46EB5926, iid, 0), NumPut("ushort", 0x582E, iid, 4), NumPut("ushort", 0x4017, iid, 6)
        NumPut("uchar", 0x9F, iid, 8), NumPut("uchar", 0xDF, iid, 9), NumPut("uchar", 0xE8, iid, 10), NumPut("uchar", 0x99, iid, 11)
        NumPut("uchar", 0x8D, iid, 12), NumPut("uchar", 0xAA, iid, 13), NumPut("uchar", 0x09, iid, 14), NumPut("uchar", 0x50, iid, 15)
        lists := []
        for shil in [2, 4]                          ; SHIL_EXTRALARGE(48) → SHIL_JUMBO(256)
            try {
                pl := 0
                if !DllCall("shell32\SHGetImageList", "int", shil, "ptr", iid, "ptr*", &pl, "int") && pl
                    lists.Push(pl)
            }
        if lists.Length
            fnGetIcon := NumGet(NumGet(lists[1], "ptr"), 10 * A_PtrSize, "ptr")   ; IImageList::GetIcon
    }
    if (IsObject(lists) && lists.Length && fnGetIcon) {
        shfi := Buffer(696, 0)
        DllCall("shell32\SHGetFileInfoW", "ptr", StrPtr(path), "uint", 0, "ptr", shfi
            , "uint", shfi.Size, "uint", 0x4000, "ptr")          ; SHGFI_SYSICONINDEX
        idx := NumGet(shfi, 8, "int")
        for pl in lists {
            hIcon := 0
            if !DllCall(fnGetIcon, "ptr", pl, "int", idx, "uint", 1, "ptr*", &hIcon, "int") && hIcon
                return hIcon                                     ; ILD_TRANSPARENT
        }
    }
    shfi := Buffer(A_PtrSize = 8 ? 696 : 692, 0)
    if DllCall("shell32\SHGetFileInfoW", "ptr", StrPtr(path), "uint", 0, "ptr", shfi
        , "uint", shfi.Size, "uint", 0x100, "ptr")               ; SHGFI_ICON | SHGFI_LARGEICON
        return NumGet(shfi, 0, "ptr")
    return 0
}

; 高质量缩放到 size × size 的新位图（用 Graphics 绘制到目标位图，HighQualityBicubic）
GpBitmapScaled(src, size) {
    iw := 0, ih := 0
    DllCall("gdiplus\GdipGetImageWidth", "ptr", src, "uint*", &iw)
    DllCall("gdiplus\GdipGetImageHeight", "ptr", src, "uint*", &ih)
    if (!iw || !ih)
        return 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", size, "int", size, "int", 0
        , "int", 0x26200A, "ptr", 0, "ptr*", &dst := 0)
    if !dst
        return 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "ptr", dst, "ptr*", &g := 0)
    DllCall("gdiplus\GdipSetInterpolationMode", "ptr", g, "int", 7)      ; HighQualityBicubic
    DllCall("gdiplus\GdipSetPixelOffsetMode", "ptr", g, "int", 2)        ; HighQuality
    DllCall("gdiplus\GdipDrawImageRectRect", "ptr", g, "ptr", src
        , "float", 0, "float", 0, "float", size, "float", size
        , "float", 0, "float", 0, "float", iw, "float", ih
        , "int", 2, "ptr", 0, "ptr", 0, "ptr", 0)
    DllCall("gdiplus\GdipDeleteGraphics", "ptr", g)
    return dst
}

; 取图标 → 转成带正确 alpha 的位图 → 分两步高质量缩放到显示尺寸
; （GDI+ 一步从 256 缩到 22 会有锯齿，先缩到 2 倍目标再缩到目标明显更锐利）
LoadIconBitmap(path, size) {
    hIcon := IconHandle(path)
    if !hIcon
        return 0
    img := GpBitmapFromIcon(hIcon)
    try DllCall("DestroyIcon", "ptr", hIcon)
    if !img
        return 0
    iw := 0, ih := 0
    DllCall("gdiplus\GdipGetImageWidth", "ptr", img, "uint*", &iw)
    DllCall("gdiplus\GdipGetImageHeight", "ptr", img, "uint*", &ih)
    out := 0
    if (iw > size * 2) {
        mid := GpBitmapScaled(img, size * 2)
        if mid {
            out := GpBitmapScaled(mid, size)
            DllCall("gdiplus\GdipDisposeImage", "ptr", mid)
        }
    }
    if !out
        out := GpBitmapScaled(img, size)
    DllCall("gdiplus\GdipDisposeImage", "ptr", img)
    return out
}

; 从 HICON 取图标的 GpBitmap。
; 不能用 GdipCreateBitmapFromHICON：实测它会把图标的透明像素变成不透明黑
; （颜色位图里 A=0 的像素，到 GpBitmap 里成了 A=255 + RGB=0），于是 .lnk / 应用图标
; 在面板上就是一个黑色方块；而 HICON 的颜色位图本身是带正确 alpha 的 32bpp，直接取像素即可。
GpBitmapFromIcon(hIcon) {
    ii := Buffer(32, 0)
    if !DllCall("user32\GetIconInfo", "ptr", hIcon, "ptr", ii)
        return 0
    hbmColor := NumGet(ii, A_PtrSize = 8 ? 24 : 16, "ptr")
    hbmMask := NumGet(ii, A_PtrSize = 8 ? 16 : 12, "ptr")
    if hbmMask
        try DllCall("DeleteObject", "ptr", hbmMask)      ; mask 实测全是 0，没有透明信息
    if !hbmColor
        return 0
    img := 0
    bm := Buffer(32, 0)
    if DllCall("gdi32\GetObjectW", "ptr", hbmColor, "int", 32, "ptr", bm) {
        w := NumGet(bm, 4, "int"), h := NumGet(bm, 8, "int")
        if (w > 0 && h > 0) {
            bi := Buffer(40, 0)
            NumPut("uint", 40, bi, 0), NumPut("int", w, bi, 4), NumPut("int", -h, bi, 8)
            NumPut("ushort", 1, bi, 12), NumPut("ushort", 32, bi, 14)
            px := Buffer(w * h * 4, 0)
            hdc := DllCall("GetDC", "ptr", 0, "ptr")
            ok := DllCall("gdi32\GetDIBits", "ptr", hdc, "ptr", hbmColor, "uint", 0, "uint", h
                , "ptr", px, "ptr", bi, "uint", 0)
            DllCall("ReleaseDC", "ptr", 0, "ptr", hdc)
            if ok {
                DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", w, "int", h, "int", 0
                    , "int", 0x26200A, "ptr", 0, "ptr*", &img := 0)      ; PixelFormat32bppARGB
                if img {
                    rc := Buffer(16, 0)
                    NumPut("int", 0, rc, 0), NumPut("int", 0, rc, 4), NumPut("int", w, rc, 8), NumPut("int", h, rc, 12)
                    bd := Buffer(32, 0)
                    if !DllCall("gdiplus\GdipBitmapLockBits", "ptr", img, "ptr", rc, "uint", 3
                        , "int", 0x26200A, "ptr", bd) {                 ; ImageLockModeReadWrite
                        scan0 := NumGet(bd, A_PtrSize = 8 ? 16 : 12, "ptr")
                        stride := NumGet(bd, 8, "int")
                        y := 0
                        while (y < h) {
                            DllCall("RtlMoveMemory", "ptr", scan0 + y * stride, "ptr", px.Ptr + y * w * 4, "uptr", w * 4)
                            y += 1
                        }
                        DllCall("gdiplus\GdipBitmapUnlockBits", "ptr", img, "ptr", bd)
                    } else {
                        DllCall("gdiplus\GdipDisposeImage", "ptr", img)
                        img := 0
                    }
                }
            }
        }
    }
    try DllCall("DeleteObject", "ptr", hbmColor)
    return img
}

; 用 GDI+ 绘制图标（img 由 GpBitmapFromIcon 生成，自带正确 alpha）
GpIcon(gp, img, x, y, size) {
    if !img
        return
    iw := size, ih := size
    DllCall("gdiplus\GdipGetImageWidth", "ptr", img, "uint*", &iw := 0)
    DllCall("gdiplus\GdipGetImageHeight", "ptr", img, "uint*", &ih := 0)
    DllCall("gdiplus\GdipDrawImageRectRect", "ptr", gp, "ptr", img
        , "float", x, "float", y, "float", size, "float", size
        , "float", 0, "float", 0, "float", iw, "float", ih
        , "int", 2, "ptr", 0, "ptr", 0, "ptr", 0)            ; UnitPixel
}

GpClip(gp, x, y, w, h) {
    DllCall("gdiplus\GdipSetClipRect", "ptr", gp, "float", x, "float", y, "float", w, "float", h, "int", 0)
}
GpUnclip(gp) {
    DllCall("gdiplus\GdipResetClip", "ptr", gp)
}

GpPath() {
    DllCall("gdiplus\GdipCreatePath", "int", 0, "ptr*", &p := 0)
    return p
}

; ======================= 工具 =======================
IsDesktopWindow(hWin) {
    if !hWin
        return false
    try {
        cls := WinGetClass("ahk_id " hWin)
        return (cls = "Progman" || cls = "WorkerW" || cls = "SysListView32")
    }
    return false
}

CursorX() {
    MouseGetPos &x
    return x
}
CursorY() {
    MouseGetPos , &y
    return y
}

; 类型名（“文本文档”之类）：按扩展名缓存 —— 同一目录里成百上千个同类型文件只查一次 shell
GetTypeName(path) {
    static cache := Map()
    SplitPath path, , , &ext
    key := StrLower(ext)
    if cache.Has(key)
        return cache[key]
    off := A_PtrSize = 8 ? 536 : 532
    shfi := Buffer(off + 160, 0)
    DllCall("shell32\SHGetFileInfoW", "ptr", StrPtr(path), "uint", 0, "ptr", shfi
        , "uint", shfi.Size, "uint", 0x400, "ptr")           ; SHGFI_TYPENAME
    t := StrGet(shfi.Ptr + off, 80, "UTF-16")
    t := RegExReplace(t, "^Microsoft\s+", "")                ; 去掉冗长前缀
    t := (t != "" ? t : "文件")
    cache[key] := t
    return t
}

FmtSize(bytes) {
    if (bytes < 1024)
        return bytes " B"
    if (bytes < 1024 ** 2)
        return Round(bytes / 1024, 1) " KB"
    if (bytes < 1024 ** 3)
        return Round(bytes / 1024 ** 2, 1) " MB"
    return Round(bytes / 1024 ** 3, 2) " GB"
}

FolderName(path) {
    path := RTrim(path, "\/")
    RegExMatch(path, "[^\\/]+$", &m)
    return m ? m[0] : path
}

WorkAreaAt(x, y) {
    loop MonitorGetCount() {
        MonitorGetWorkArea A_Index, &l, &t, &r, &b
        if (x >= l && x < r && y >= t && y < b)
            return {left: l, top: t, right: r, bottom: b}
    }
    MonitorGetWorkArea 1, &l, &t, &r, &b
    return {left: l, top: t, right: r, bottom: b}
}

S(v) => Round(v * A_ScreenDPI / 96)

Hex(c) => Format("{:06X}", c)

ApplyRoundedCorners(hwnd) {
    if (VerCompare(A_OSVersion, "10.0.22000") >= 0) {
        pref := Buffer(4, 0)
        NumPut("uint", 2, pref)                              ; DWMWCP_ROUND
        try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "uint", 33, "ptr", pref, "uint", 4)
    }
    ; 去掉窗口阴影（黑色投影）
    if (VerCompare(A_OSVersion, "10.0") >= 0) {
        policy := Buffer(4, 0)
        NumPut("uint", 1, policy)                            ; DWMNCRP_DISABLED
        try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "uint", 2, "ptr", policy, "uint", 4)
    }
}

; 收起悬停桌面图标时系统弹出的文件夹提示框（否则会盖住面板）
HideShellTooltips() {
    DetectHiddenWindows true
    for hwnd in WinGetList("ahk_class tooltips_class32") {
        try DllCall("SendMessageW", "ptr", hwnd, "uint", 0x41C, "ptr", 0, "ptr", 0) ; TTM_POP
    }
}

; 调试日志（CFG.Debug = true 时写入 trace.txt）
Trace(msg) {
    global CFG
    if !CFG.Debug
        return
    try FileAppend(Format("[{}] {}`n", A_TickCount, msg), A_ScriptDir "\trace.txt", "UTF-8")
}

; ======================= 主题 =======================
InitTheme() {
    global THEME
    light := true
    try light := RegRead("HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
        , "AppsUseLightTheme") != 0
    ARGB(rgb, a := 255) => ((a & 0xFF) << 24) | (rgb & 0xFFFFFF)
    if light {
        THEME := {
            BGRGB: Hex(0xFAFAFC), BG: ARGB(0xFAFAFC), LINE: ARGB(0xE9E9EF),
            FG: ARGB(0x1A1D23), FG2: ARGB(0x2C313A), SUB: ARGB(0x8A93A1), SUB2: ARGB(0x99A2AF),
            HOVER: ARGB(0xEFEEF4), PILL: ARGB(0xEDEFF3), SCRUB: ARGB(0xC7CCD6)
        }
    } else {
        THEME := {
            BGRGB: Hex(0x202124), BG: ARGB(0x202124), LINE: ARGB(0x323439),
            FG: ARGB(0xF0F1F4), FG2: ARGB(0xE2E4E9), SUB: ARGB(0x9AA3B2), SUB2: ARGB(0x79828F),
            HOVER: ARGB(0x2D2F34), PILL: ARGB(0x2C2E33), SCRUB: ARGB(0x4A4E56)
        }
    }
}

; ======================= 调试 =======================
; 命令行加 -test：在指定位置弹出示例面板（自测用）
; AutoHotkey64.exe FolderDrawer.ahk -test [x] [y] [文件夹路径]
if (A_Args.Length && A_Args[1] = "-test") {
    mx := A_Args.Length >= 2 ? Integer(A_Args[2]) : 300
    my := A_Args.Length >= 3 ? Integer(A_Args[3]) : 300
    path := A_Args.Length >= 4 ? A_Args[4] : A_Desktop   ; A_Args[1]="-test", [2]=x, [3]=y, [4]=路径（可省略）
    g.freeze := true                     ; 测试时不因鼠标离开而关闭
    SetTimer(DebugDumpDesktop, -200)     ; 自检：桌面列表跨进程读取
    SetTimer(() => DebugOpen(mx, my, path), -400)
    SetTimer(DebugCascade, -1200)        ; 自动级联 + 高亮，方便截图
}

; -dump：只导出桌面图标清单后退出
if (A_Args.Length && A_Args[1] = "-dump") {
    loop 10 {
        if g.rlv
            break
        StartTool()
        Sleep 300
    }
    DebugDumpDesktop()
    ExitApp
}

; -hit：检查鼠标命中链路（坐标→命中项→窗口→是否文件夹）
if (A_Args.Length && A_Args[1] = "-hit") {
    loop 10 {
        if g.rlv
            break
        StartTool()
        Sleep 300
    }
    MouseGetPos &mx, &my, &hWin
    out := "cursor=" mx "," my "`n"
    out .= "window hwnd=" hWin " class=[" (hWin ? WinGetClass("ahk_id " hWin) : "") "] isDesktop=" IsDesktopWindow(hWin) "`n"
    idx := g.rlv.HitTestScreen(mx, my)
    out .= "hittest idx=" idx "`n"
    if (idx >= 0) {
        out .= "name=[" g.rlv.ItemText(idx) "]`n"
        info := DesktopItem(idx)
        out .= "resolved path=[" info.path "] target=[" info.target "] isDir=" info.isDir "`n"
    }
    try FileAppend(out, A_ScriptDir "\desktopinfo.txt", "UTF-8")
    ExitApp
}

; 自检：读取桌面图标（验证跨进程 ListView 访问）
DebugDumpDesktop() {
    global g
    if !g.rlv
        return
    rlv := g.rlv
    out := "count=" rlv.ItemCount() "`n"
    loop Min(20, rlv.ItemCount()) {
        i := A_Index - 1
        name := rlv.ItemText(i)
        r := rlv.ItemRectScreen(i, 1)
        info := DesktopItem(i)
        out .= Format("[{}] name=[{}] dir={} iconRect={},{},{},{}`n"
            , i, name, info.isDir, r.left, r.top, r.right, r.bottom)
    }
    try FileAppend(out, A_ScriptDir "\desktopinfo.txt", "UTF-8")
}

; 自检：高亮第 1 行并级联展开，再高亮子面板第 2 行
DebugCascade() {
    global g
    if (g.popups.Length < 1)
        return
    p := g.popups[1]
    if (p.items.Length < 1)
        return
    p.Highlight(0)
    if p.items[1].isDir
        OpenSub(p, 0, p.items[1])
    if (g.popups.Length > 1)
        g.popups[2].Highlight(1)
}

DebugOpen(mx, my, path) {
    global g
    if !FileExist(path)
        path := A_Desktop
    p := Peek(1, path, {left: mx - 40, top: my - 40, right: mx, bottom: my}, "")
    g.popups := [p]
    g.rootIdx := -99
    p.Show()
}

; Ctrl+Alt+D：在鼠标处弹出示例面板（自测用）
^!d:: {
    global g
    MouseGetPos &mx, &my
    path := A_Desktop
    try {
        Loop Files A_Desktop "\*", "D" {
            path := A_LoopFileFullPath
            break
        }
    }
    DebugOpen(mx, my, path)
}

; Ctrl+Alt+Q：退出
^!q::ExitApp()

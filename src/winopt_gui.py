# -*- coding: utf-8 -*-
"""
Windows 10 / 11 优化工具 —— 图形界面外壳。

分工：
  * 本程序只负责界面、参数编排、子进程管理与实时日志渲染
  * 所有实际改动、备份清单、回滚逻辑，全部由内嵌的 Optimize-WinClient.ps1 完成
  * 因此 GUI 版与命令行版共享同一套行为与同一份变更清单目录
"""

import ctypes
import os
import queue
import subprocess
import sys
import threading
import traceback
import winreg

import tkinter as tk
import tkinter.font as tkfont
from tkinter import ttk

APP_NAME = "Windows 10 / 11 优化工具"
APP_VERSION = "1.1.0"
CODENAME = "口径 v1.0"
PS1_NAME = "Optimize-WinClient.ps1"
ICO_NAME = "icon.ico"
BACKUP_DIR = os.path.join(os.environ.get("ProgramData", r"C:\ProgramData"), "WinOpt")

CREATE_NO_WINDOW = 0x08000000

ROLES = [
    ("Office", "办公机", "批量下发，单项可回滚优先于极致瘦身。"),
    ("Dev", "开发机", "不动虚拟化、WSL、内核隔离与驱动签名。"),
    ("Design", "设计机", "重驱动与色彩稳定，不做激进裁剪。"),
    ("Personal", "个人机", "单机自用，允许更激进的动作（仍不碰安全项）。"),
]

DARK = {
    "bg": "#0C141C", "panel": "#111C26", "card": "#16232F", "line": "#1F2F3D",
    "text": "#DCE7F0", "dim": "#7E93A6", "faint": "#5A6E80",
    "accent": "#2FD3E3", "accent_text": "#04202A", "sel": "#17303E",
    "ok": "#4ADE80", "warn": "#F5B942", "err": "#F2705F", "log_bg": "#0A1219",
    "btn": "#1B2937", "btn_hover": "#243444",
}
LIGHT = {
    "bg": "#E4EAF1", "panel": "#FFFFFF", "card": "#F4F7FA", "line": "#CFD9E3",
    "text": "#17242F", "dim": "#5D7183", "faint": "#8A9BAB",
    "accent": "#0E7490", "accent_text": "#FFFFFF", "sel": "#E3EEF3",
    "ok": "#15803D", "warn": "#B45309", "err": "#BE123C", "log_bg": "#FBFCFE",
    "btn": "#EDF2F6", "btn_hover": "#E1E9F0",
}


# ------------------------------------------------------------------ 环境

def enable_dpi():
    if os.name != "nt":
        return
    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
        return
    except Exception:
        pass
    try:
        ctypes.windll.user32.SetProcessDPIAware()
    except Exception:
        pass


def is_admin():
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def resource_path(name):
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, name)


def read_os_info():
    info = {"name": "Windows", "version": "", "build": 0, "full": "Windows"}
    try:
        key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                             r"SOFTWARE\Microsoft\Windows NT\CurrentVersion")

        def get(n):
            try:
                return winreg.QueryValueEx(key, n)[0]
            except Exception:
                return ""

        product = str(get("ProductName"))
        version = str(get("DisplayVersion"))
        build = str(get("CurrentBuildNumber"))
        ubr = str(get("UBR"))
        winreg.CloseKey(key)
        try:
            bnum = int(build)
        except Exception:
            bnum = 0
        # Win11 的 ProductName 仍写作 "Windows 10"，必须以 Build 号为准
        name = "Windows 11" if bnum >= 22000 else product
        info.update(name=name, version=version, build=bnum)
        info["full"] = ("%s %s (Build %s.%s)" % (name, version, build, ubr)).replace("  ", " ")
    except Exception:
        pass
    return info


def latest_manifest():
    try:
        files = [f for f in os.listdir(BACKUP_DIR)
                 if f.startswith("manifest-") and f.endswith(".json")]
        if not files:
            return None
        files.sort(reverse=True)
        return files[0]
    except Exception:
        return None


def smart_decode(raw):
    for enc in ("utf-8", "gbk"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def set_dark_titlebar(window, dark=True):
    """让系统标题栏跟随深色主题；不支持的版本静默跳过。"""
    if os.name != "nt":
        return
    try:
        window.update_idletasks()
        hwnd = ctypes.windll.user32.GetParent(window.winfo_id())
        value = ctypes.c_int(1 if dark else 0)
        for attr in (20, 19):  # DWMWA_USE_IMMERSIVE_DARK_MODE 新旧两个编号
            ctypes.windll.dwmapi.DwmSetWindowAttribute(
                hwnd, attr, ctypes.byref(value), ctypes.sizeof(value))
    except Exception:
        pass


def elevate_self():
    params = " ".join(['"%s"' % a for a in sys.argv[1:]]) or None
    try:
        rc = ctypes.windll.shell32.ShellExecuteW(
            None, "runas", sys.executable, params, None, 1)
        return rc > 32
    except Exception:
        return False


# ------------------------------------------------------------------ 主窗口

class App:
    def __init__(self, root):
        self.root = root
        self.os_info = read_os_info()
        self.admin = is_admin()
        self.role = "Office"
        self.proc = None
        self.q = queue.Queue()
        self.busy = False
        self.theme_name = "dark"
        self.t = dict(DARK)
        self.seg_btns = {}

        self.scale = self._compute_scale()
        root.tk.call("tk", "scaling", self.scale * 96.0 / 72.0)

        self._pick_fonts()
        self._build_window()
        self.apply_theme()
        self._render_welcome()
        self._refresh_manifest_card()
        self._set_status("就绪", "idle")

    # ---------------- 尺寸与字体

    def _compute_scale(self):
        try:
            dpi = float(self.root.winfo_fpixels("1i"))
            if dpi < 72 or dpi > 400:
                return 1.0
            return dpi / 96.0
        except Exception:
            return 1.0

    def px(self, n):
        return max(1, int(round(n * self.scale)))

    def _pick_fonts(self):
        fams = set(tkfont.families())
        ui = "Microsoft YaHei UI"
        if ui not in fams:
            ui = "Microsoft YaHei" if "Microsoft YaHei" in fams else "Segoe UI"
        mono = "Consolas"
        if mono not in fams:
            mono = "Cascadia Mono" if "Cascadia Mono" in fams else "Courier New"

        self.f_title = tkfont.Font(family=ui, size=-self.px(19), weight="bold")
        self.f_sub = tkfont.Font(family=ui, size=-self.px(12))
        self.f_body = tkfont.Font(family=ui, size=-self.px(13))
        self.f_small = tkfont.Font(family=ui, size=-self.px(11))
        self.f_section = tkfont.Font(family=ui, size=-self.px(11), weight="bold")
        self.f_btn = tkfont.Font(family=ui, size=-self.px(13))
        self.f_log = tkfont.Font(family=mono, size=-self.px(12))

    # ---------------- 骨架

    def _build_window(self):
        r = self.root
        r.title("%s v%s" % (APP_NAME, APP_VERSION))
        r.minsize(self.px(940), self.px(600))
        w, h = self.px(1160), self.px(760)
        try:
            sw, sh = r.winfo_screenwidth(), r.winfo_screenheight()
            r.geometry("%dx%d+%d+%d" % (w, h, max(0, (sw - w) // 2),
                                        max(0, (sh - h) // 3)))
        except Exception:
            r.geometry("%dx%d" % (w, h))
        try:
            ico = resource_path(ICO_NAME)
            if os.path.isfile(ico):
                r.iconbitmap(default=ico)
        except Exception:
            pass

        self.style = ttk.Style(r)
        try:
            self.style.theme_use("clam")
        except Exception:
            pass

        r.columnconfigure(0, weight=1)
        r.rowconfigure(2, weight=1)   # 0 头部 / 1 提示条 / 2 主体 / 3 状态栏

        self._build_header()
        self._build_body()
        self._build_statusbar()

    def _build_header(self):
        hdr_line = ttk.Frame(self.root, style="Line.TFrame", padding=(0, 0, 0, 1))
        hdr_line.grid(row=0, column=0, sticky="ew")
        self.header = ttk.Frame(hdr_line, style="Header.TFrame",
                                padding=(self.px(18), self.px(13)))
        self.header.pack(fill="x")
        self.header.columnconfigure(1, weight=1)

        self.shield = tk.Canvas(self.header, width=self.px(38), height=self.px(38),
                                highlightthickness=0, bd=0)
        self.shield.grid(row=0, column=0, rowspan=2, sticky="w")
        self._draw_shield()

        self.lbl_title = ttk.Label(self.header, text=APP_NAME, style="Title.TLabel")
        self.lbl_title.grid(row=0, column=1, sticky="sw", padx=(self.px(12), 0))
        self.lbl_sub = ttk.Label(self.header, style="Sub.TLabel")
        self.lbl_sub.grid(row=1, column=1, sticky="nw", padx=(self.px(12), 0))

        right = ttk.Frame(self.header, style="Header.TFrame")
        right.grid(row=0, column=2, rowspan=2, sticky="e")

        self.badge_admin = ttk.Label(right, style="Badge.TLabel")
        self.badge_admin.pack(side="left", padx=(0, self.px(6)))
        self.badge_theme = ttk.Button(right, style="Ghost.TButton",
                                      width=5, command=self.toggle_theme)
        self.badge_theme.pack(side="left")

        self.eol = None
        if 19041 <= self.os_info["build"] < 22000:
            self.eol = tk.Label(
                self.root,
                text="  该机为 Win10 22H2：常规支持已于 2025-10-14 结束，"
                     "消费者 ESU 已于 2026-10-13 到期。建议优先升级或确认企业 ESU 覆盖。  ",
                anchor="w", justify="left")
            self.eol.grid(row=1, column=0, sticky="ew")

    def _draw_shield(self):
        c = self.shield
        c.delete("all")
        t = self.t
        s = self.px(38)
        p = self.px(2)
        c.configure(bg=t["panel"])
        c.create_oval(p, p, s - p, s - p, fill=t["card"], outline=t["line"], width=1)
        pts = [s * 0.50, s * 0.20, s * 0.78, s * 0.32, s * 0.78, s * 0.55,
               s * 0.50, s * 0.82, s * 0.22, s * 0.55, s * 0.22, s * 0.32]
        c.create_polygon(pts, fill=t["sel"], outline=t["accent"], width=1)
        c.create_line(s * 0.38, s * 0.50, s * 0.47, s * 0.60, s * 0.64, s * 0.40,
                      fill=t["accent"], width=max(2, self.px(2.4)),
                      capstyle="round", joinstyle="round")

    def _build_body(self):
        body = ttk.Frame(self.root, style="Root.TFrame")
        body.grid(row=2, column=0, sticky="nsew")
        body.columnconfigure(0, minsize=self.px(292))
        body.columnconfigure(1, weight=1)
        body.rowconfigure(0, weight=1)

        # ---- 左栏（外包 1px 描边）
        side_border = ttk.Frame(body, style="Line.TFrame", padding=1)
        side_border.grid(row=0, column=0, sticky="nsew",
                         padx=(self.px(14), 0), pady=(0, self.px(12)))
        self.side = ttk.Frame(side_border, style="Panel.TFrame",
                              padding=(self.px(15), self.px(13)))
        self.side.pack(fill="both", expand=True)

        ttk.Label(self.side, text="机型", style="Section.TLabel").pack(anchor="w")

        seg = ttk.Frame(self.side, style="Panel.TFrame")
        seg.pack(fill="x", pady=(self.px(7), self.px(6)))
        for i, (key, name, _hint) in enumerate(ROLES):
            seg.columnconfigure(i, weight=1, uniform="seg")
            b = ttk.Button(seg, text=name, style="SegOff.TButton",
                           command=lambda k=key: self.set_role(k))
            b.grid(row=0, column=i, sticky="ew",
                   padx=(0 if i == 0 else self.px(2), 0))
            self.seg_btns[key] = b

        self.lbl_role_hint = ttk.Label(self.side, text="", style="Faint.TLabel",
                                       wraplength=self.px(252), justify="left")
        self.lbl_role_hint.pack(anchor="w", pady=(0, self.px(2)))

        ttk.Separator(self.side, orient="horizontal").pack(
            fill="x", pady=(self.px(12), self.px(10)))

        ttk.Label(self.side, text="执行", style="Section.TLabel").pack(anchor="w")
        ttk.Label(self.side, text="先演练，再应用", style="Faint.TLabel"
                  ).pack(anchor="w", pady=(self.px(2), self.px(8)))

        self.btn_report = self._make_button("采集基线（只读）", "Secondary",
                                            lambda: self.start("report"))
        self.btn_dry = self._make_button("演练 L1（不写入）", "Secondary",
                                         lambda: self.start("dry"))
        self.btn_l1 = self._make_button("应用 L1", "Primary",
                                        lambda: self.start("l1"))
        self.btn_l2 = self._make_button("应用 L1 + L2", "Secondary",
                                        lambda: self.start("l2"))
        self.btn_rollback = self._make_button("回滚最近一次变更", "Danger",
                                              lambda: self.start("rollback"))

        ttk.Separator(self.side, orient="horizontal").pack(
            fill="x", pady=(self.px(12), self.px(10)))

        ttk.Label(self.side, text="建议顺序", style="Faint.TLabel").pack(
            anchor="w", pady=(0, self.px(5)))
        for num, txt in (("1", "采集基线 · 记录现状"),
                         ("2", "演练 L1 · 核对清单"),
                         ("3", "应用 L1 · 30 天后复测")):
            rowf = ttk.Frame(self.side, style="Panel.TFrame")
            rowf.pack(fill="x", pady=(0, self.px(4)))
            ttk.Label(rowf, text=num, style="StepNum.TLabel").pack(
                side="left", padx=(0, self.px(8)))
            ttk.Label(rowf, text=txt, style="StepText.TLabel").pack(side="left")

        ttk.Separator(self.side, orient="horizontal").pack(
            fill="x", pady=(self.px(10), self.px(8)))

        self.btn_boundary = ttk.Button(self.side, text="本工具不碰哪些配置",
                                       style="Link.TButton",
                                       command=self.show_boundary)
        self.btn_boundary.pack(anchor="w")

        # 底部状态卡片：固定在左栏底部，避免大片留白
        card_line = ttk.Frame(self.side, style="Line.TFrame", padding=1)
        card_line.pack(side="bottom", fill="x", pady=(self.px(10), 0))
        self.card = ttk.Frame(card_line, style="Card.TFrame",
                              padding=(self.px(10), self.px(8)))
        self.card.pack(fill="both", expand=True)
        self.card.columnconfigure(1, weight=1)

        ttk.Label(self.card, text="最近变更", style="CardKey.TLabel").grid(
            row=0, column=0, sticky="w", padx=(0, self.px(8)))
        self.lbl_manifest = ttk.Label(self.card, text="—", style="CardVal.TLabel")
        self.lbl_manifest.grid(row=0, column=1, sticky="e")
        ttk.Label(self.card, text="回滚可用", style="CardKey.TLabel").grid(
            row=1, column=0, sticky="w", padx=(0, self.px(8)))
        self.lbl_rollback = ttk.Label(self.card, text="—", style="CardVal.TLabel")
        self.lbl_rollback.grid(row=1, column=1, sticky="e")

        # ---- 右侧日志
        right = ttk.Frame(body, style="Root.TFrame")
        right.grid(row=0, column=1, sticky="nsew",
                   padx=(self.px(12), self.px(14)), pady=(0, self.px(12)))
        right.columnconfigure(0, weight=1)
        right.rowconfigure(1, weight=1)

        bar = ttk.Frame(right, style="Root.TFrame")
        bar.grid(row=0, column=0, sticky="ew", pady=(0, self.px(7)))
        bar.columnconfigure(1, weight=1)
        ttk.Label(bar, text="运行日志", style="Section.TLabel").grid(
            row=0, column=0, sticky="w")
        ttk.Label(bar, text="实时输出，可整段复制", style="Faint.TLabel").grid(
            row=0, column=1, sticky="w", padx=(self.px(8), 0))
        ttk.Button(bar, text="清空", style="Ghost.TButton", width=5,
                   command=self.clear_log).grid(row=0, column=2, padx=(0, self.px(6)))
        ttk.Button(bar, text="复制", style="Ghost.TButton", width=5,
                   command=self.copy_log).grid(row=0, column=3, padx=(0, self.px(6)))
        ttk.Button(bar, text="输出目录", style="Ghost.TButton", width=8,
                   command=self.open_backup_dir).grid(row=0, column=4)

        # 外框 1px：靠 Line.TFrame 的底色当描边
        border = ttk.Frame(right, style="Line.TFrame", padding=1)
        border.grid(row=1, column=0, sticky="nsew")
        border.columnconfigure(0, weight=1)
        border.rowconfigure(0, weight=1)

        wrap = ttk.Frame(border, style="Card.TFrame")
        wrap.grid(row=0, column=0, sticky="nsew")
        wrap.columnconfigure(0, weight=1)
        wrap.rowconfigure(0, weight=1)

        self.log = tk.Text(wrap, wrap="word", bd=0, highlightthickness=0,
                           padx=self.px(12), pady=self.px(9),
                           font=self.f_log, spacing1=self.px(1),
                           spacing3=self.px(2), state="disabled")
        self.log.grid(row=0, column=0, sticky="nsew")
        self.sb = ttk.Scrollbar(wrap, orient="vertical", command=self.log.yview)
        self.sb.grid(row=0, column=1, sticky="ns")
        self.log.configure(yscrollcommand=self.sb.set)

    def _make_button(self, text, kind, cmd):
        b = ttk.Button(self.side, text=text, style="%s.TButton" % kind, command=cmd)
        b.pack(fill="x", pady=(0, self.px(6)))
        return b

    def _build_statusbar(self):
        bar = ttk.Frame(self.root, style="Status.TFrame",
                        padding=(self.px(16), self.px(7)))
        bar.grid(row=3, column=0, sticky="ew")
        bar.columnconfigure(2, weight=1)

        self.dot = tk.Canvas(bar, width=self.px(10), height=self.px(10),
                             highlightthickness=0, bd=0)
        self.dot.grid(row=0, column=0, padx=(0, self.px(8)))
        self.dot_id = self.dot.create_oval(1, 1, self.px(9), self.px(9),
                                           outline="", width=0)

        self.lbl_status = ttk.Label(bar, text="就绪", style="Status.TLabel")
        self.lbl_status.grid(row=0, column=1, sticky="w")

        self.holder = ttk.Frame(bar, style="Status.TFrame")
        self.holder.grid(row=0, column=2, sticky="e")

        self.progress = ttk.Progressbar(self.holder, mode="indeterminate",
                                        length=self.px(130),
                                        style="Bar.Horizontal.TProgressbar")
        self.btn_stop = ttk.Button(self.holder, text="停止", style="Ghost.TButton",
                                   width=6, state="disabled", command=self.stop)
        # 空闲时两者都不 pack，避免"看起来正在跑"

    # ---------------- 主题

    def toggle_theme(self):
        self.theme_name = "light" if self.theme_name == "dark" else "dark"
        self.t = dict(LIGHT if self.theme_name == "light" else DARK)
        self.apply_theme()

    def apply_theme(self):
        t = self.t
        st = self.style
        self.root.configure(bg=t["bg"])

        st.configure("Root.TFrame", background=t["bg"])
        st.configure("Header.TFrame", background=t["panel"])
        st.configure("Panel.TFrame", background=t["panel"])
        st.configure("Card.TFrame", background=t["log_bg"])
        st.configure("Status.TFrame", background=t["panel"])
        st.configure("Line.TFrame", background=t["line"])

        st.configure("Title.TLabel", background=t["panel"], foreground=t["text"],
                     font=self.f_title)
        st.configure("Sub.TLabel", background=t["panel"], foreground=t["dim"],
                     font=self.f_sub)
        st.configure("Section.TLabel", background=t["panel"], foreground=t["text"],
                     font=self.f_section)
        st.configure("Faint.TLabel", background=t["panel"], foreground=t["faint"],
                     font=self.f_small)
        st.configure("Status.TLabel", background=t["panel"], foreground=t["dim"],
                     font=self.f_small)
        st.configure("Badge.TLabel", background=t["card"], foreground=t["dim"],
                     font=self.f_small, padding=(self.px(7), self.px(3)))

        st.configure("SegOff.TButton", background=t["card"], foreground=t["dim"],
                     font=self.f_small, borderwidth=0, focusthickness=0,
                     padding=(self.px(2), self.px(6)))
        st.map("SegOff.TButton",
               background=[("active", t["btn_hover"]), ("disabled", t["panel"])],
               foreground=[("active", t["text"]), ("disabled", t["faint"])])
        st.configure("SegOn.TButton", background=t["accent"],
                     foreground=t["accent_text"], font=self.f_small,
                     borderwidth=0, focusthickness=0,
                     padding=(self.px(2), self.px(6)))
        st.map("SegOn.TButton",
               background=[("active", t["accent"]), ("disabled", t["line"])],
               foreground=[("disabled", t["faint"])])

        for name, bg, fg in (("Primary", t["accent"], t["accent_text"]),
                             ("Secondary", t["btn"], t["text"]),
                             ("Danger", t["btn"], t["err"])):
            st.configure("%s.TButton" % name, background=bg, foreground=fg,
                         font=self.f_btn, borderwidth=0, focusthickness=0,
                         padding=(self.px(12), self.px(8)))
            active_bg = t["accent"] if name == "Primary" else t["btn_hover"]
            st.map("%s.TButton" % name,
                   background=[("disabled", t["card"]), ("active", active_bg)],
                   foreground=[("disabled", t["faint"]), ("active", fg)])

        st.configure("Ghost.TButton", background=t["card"], foreground=t["dim"],
                     font=self.f_small, borderwidth=0, focusthickness=0,
                     padding=(self.px(8), self.px(4)))
        st.map("Ghost.TButton", background=[("active", t["btn_hover"])],
               foreground=[("active", t["text"])])

        st.configure("Link.TButton", background=t["panel"], foreground=t["accent"],
                     font=self.f_small, borderwidth=0, focusthickness=0,
                     padding=(0, self.px(2)))
        st.map("Link.TButton", foreground=[("active", t["text"])])

        st.configure("Bar.Horizontal.TProgressbar", background=t["accent"],
                     troughcolor=t["card"], borderwidth=0, thickness=self.px(5))
        st.configure("DialogBody.TLabel", background=t["panel"], foreground=t["text"],
                     font=self.f_body)

        st.configure("StepNum.TLabel", background=t["panel"], foreground=t["accent"],
                     font=self.f_section)
        st.configure("StepText.TLabel", background=t["panel"], foreground=t["dim"],
                     font=self.f_small)

        st.configure("CardKey.TLabel", background=t["log_bg"], foreground=t["faint"],
                     font=self.f_small)
        st.configure("CardVal.TLabel", background=t["log_bg"], foreground=t["text"],
                     font=self.f_small)

        st.configure("TSeparator", background=t["line"])
        st.configure("TScrollbar", background=t["btn"], troughcolor=t["log_bg"],
                     borderwidth=0, arrowcolor=t["dim"])
        st.map("TScrollbar", background=[("active", t["btn_hover"])])

        try:
            self.log.configure(bg=t["log_bg"], fg=t["text"],
                               insertbackground=t["accent"],
                               selectbackground=t["sel"], selectforeground=t["text"])
            self.log.tag_configure("meta", foreground=t["accent"])
            self.log.tag_configure("info", foreground=t["text"])
            self.log.tag_configure("ok", foreground=t["ok"])
            self.log.tag_configure("warn", foreground=t["warn"])
            self.log.tag_configure("error", foreground=t["err"])
            self.log.tag_configure("skip", foreground=t["faint"])
        except Exception:
            pass

        if self.eol is not None:
            self.eol.configure(bg=t["warn"], fg="#20160A", font=self.f_small)

        set_dark_titlebar(self.root, self.theme_name == "dark")
        self.badge_theme.configure(text="浅色" if self.theme_name == "dark" else "深色")
        try:
            self._refresh_manifest_card()
        except Exception:
            pass
        self._draw_shield()
        self._sync_seg()
        self._refresh_badges()
        self._set_dot("run" if self.busy else "idle")

    def _refresh_manifest_card(self):
        mf = latest_manifest()
        if mf:
            stamp = mf.replace("manifest-", "").replace(".json", "")
            try:
                nice = "%s-%s-%s %s:%s" % (stamp[0:4], stamp[4:6], stamp[6:8],
                                           stamp[9:11], stamp[11:13])
            except Exception:
                nice = stamp
            self.lbl_manifest.configure(text=nice)
            self.lbl_rollback.configure(text="可回滚", foreground=self.t["ok"])
        else:
            self.lbl_manifest.configure(text="无")
            self.lbl_rollback.configure(text="不可回滚", foreground=self.t["faint"])

    def _refresh_badges(self):
        t = self.t
        if self.admin:
            self.badge_admin.configure(text="管理员", foreground=t["ok"])
        else:
            self.badge_admin.configure(text="普通用户 · HKLM 跳过", foreground=t["warn"])

    def _update_sub(self):
        role_name = dict((k, n) for k, n, _ in ROLES)[self.role]
        self.lbl_sub.configure(
            text="%s   ·   %s   ·   %s" % (self.os_info["full"], role_name, CODENAME))

    # ---------------- 状态与日志

    def _set_dot(self, kind):
        color = {"idle": self.t["faint"], "run": self.t["accent"],
                 "ok": self.t["ok"], "err": self.t["err"],
                 "warn": self.t["warn"]}[kind]
        try:
            self.dot.itemconfigure(self.dot_id, fill=color)
            self.dot.configure(bg=self.t["panel"])
        except Exception:
            pass

    def _set_status(self, text, kind="idle"):
        self.lbl_status.configure(text=text)
        self._set_dot(kind)

    def logln(self, text, tag="info"):
        self.log.configure(state="normal")
        self.log.insert("end", text + "\n", tag)
        self.log.see("end")
        self.log.configure(state="disabled")

    def clear_log(self):
        if self.busy:
            return
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")

    def copy_log(self):
        try:
            self.root.clipboard_clear()
            self.root.clipboard_append(self.log.get("1.0", "end-1c"))
            self._set_status("日志已复制到剪贴板", "ok")
        except Exception:
            self._set_status("复制失败", "err")

    def open_backup_dir(self):
        try:
            if not os.path.isdir(BACKUP_DIR):
                os.makedirs(BACKUP_DIR, exist_ok=True)
            os.startfile(BACKUP_DIR)
        except Exception as exc:
            self._set_status("无法打开目录：%s" % exc, "err")

    def _render_welcome(self):
        self.clear_log()
        self._update_sub()
        self.logln("Windows 10 / 11 优化工具  v%s" % APP_VERSION, "meta")
        self.logln(self.os_info["full"], "skip")
        self.logln("")
        self.logln("建议顺序：采集基线 → 演练 L1 → 应用 L1 →（按需）L1 + L2", "info")
        self.logln("")
        self.logln("· 采集基线：只读，报告写入 %s" % BACKUP_DIR, "skip")
        self.logln("· 演练 L1 ：只打印将要改动的项，不写入注册表", "skip")
        self.logln("· 应用前自动记录原值；回滚按最近一次清单逆序还原", "skip")
        self.logln("")
        if 19041 <= self.os_info["build"] < 22000:
            self.logln("注意：该机为 Win10 22H2，常规支持已于 2025-10-14 结束，", "warn")
            self.logln("      消费者 ESU 已于 2026-10-13 到期。建议优先升级或确认企业 ESU。", "warn")
            self.logln("")

    def show_boundary(self):
        self.logln("")
        self.logln("【本工具永不会修改的配置】", "meta")
        for line in [
            "  1. Microsoft Defender 实时防护",
            "  2. VBS / HVCI（内存完整性、内核隔离）",
            "  3. Windows Update 及其服务",
            "  4. BitLocker",
            "  5. 页面文件（虚拟内存）",
            "  6. Windows Search 索引服务",
        ]:
            self.logln(line, "info")
        self.logln("")
        self.logln("理由：这几项属安全与可用性边界，收益无法量化、故障滞后且难归因，", "skip")
        self.logln("      只能走变更审批单独处理，不能混在批量优化里下发。", "skip")
        self.logln("")
        self.logln("两道安全闸门：不加 -Apply 一律只演练；每次写入前记录原值到", "skip")
        self.logln("%s\\manifest-*.json，回滚时逆序还原、本次新建的键整键删除。" % BACKUP_DIR, "skip")
        self.logln("")

    # ---------------- 机型切换

    def _sync_seg(self):
        for key, btn in self.seg_btns.items():
            btn.configure(style="SegOn.TButton" if key == self.role else "SegOff.TButton")
        try:
            self.lbl_role_hint.configure(text=dict((k, h) for k, _n, h in ROLES)[self.role])
        except Exception:
            pass

    def set_role(self, key):
        if self.busy or key == self.role:
            return
        self.role = key
        name = dict((k, n) for k, n, _ in ROLES)[key]
        self._sync_seg()
        self._update_sub()
        self._set_status("机型已切换为 %s" % name, "idle")

    # ---------------- 确认框

    def ask(self, title, message, ok_text="继续", danger=False):
        t = self.t
        dlg = tk.Toplevel(self.root)
        dlg.title(title)
        dlg.transient(self.root)
        dlg.resizable(False, False)
        dlg.configure(bg=t["panel"])
        try:
            dlg.iconbitmap(default=resource_path(ICO_NAME))
        except Exception:
            pass

        wrap = ttk.Frame(dlg, style="Panel.TFrame",
                         padding=(self.px(22), self.px(18)))
        wrap.pack(fill="both", expand=True)

        ttk.Label(wrap, text=title, style="Section.TLabel").pack(anchor="w")
        ttk.Label(wrap, text=message, style="DialogBody.TLabel",
                  wraplength=self.px(430), justify="left").pack(
                      anchor="w", pady=(self.px(10), self.px(18)))

        row = ttk.Frame(wrap, style="Panel.TFrame")
        row.pack(anchor="e")
        result = {"ok": False}

        def close(v):
            result["ok"] = v
            dlg.destroy()

        ttk.Button(row, text="取消", style="Secondary.TButton",
                   command=lambda: close(False)).pack(side="left", padx=(0, self.px(8)))
        ttk.Button(row, text=ok_text,
                   style="Danger.TButton" if danger else "Primary.TButton",
                   command=lambda: close(True)).pack(side="left")

        dlg.bind("<Escape>", lambda e: close(False))
        dlg.bind("<Return>", lambda e: close(True))

        dlg.update_idletasks()
        try:
            dx = self.root.winfo_rootx() + (self.root.winfo_width() - dlg.winfo_width()) // 2
            dy = self.root.winfo_rooty() + (self.root.winfo_height() - dlg.winfo_height()) // 3
            dlg.geometry("+%d+%d" % (max(0, dx), max(0, dy)))
        except Exception:
            pass
        set_dark_titlebar(dlg, self.theme_name == "dark")
        dlg.grab_set()
        dlg.focus_force()
        self.root.wait_window(dlg)
        return result["ok"]

    # ---------------- 执行

    ACTIONS = {
        "report":   ("采集基线", ["-Level", "Report"], False, None),
        "dry":      ("演练 L1", ["-Level", "L1"], False, None),
        "l1":       ("应用 L1", ["-Level", "L1", "-Apply"], True, None),
        "l2":       ("应用 L1 + L2", ["-Level", "L2", "-Apply"], True, "l2"),
        "rollback": ("回滚最近一次变更", ["-Rollback"], True, "rb"),
    }

    def _build_ps(self, args):
        ps1 = resource_path(PS1_NAME)
        if not os.path.isfile(ps1):
            return None
        parts, i = [], 0
        while i < len(args):
            a = args[i]
            if a in ("-Level", "-Role", "-BackupDir") and i + 1 < len(args):
                parts.append("%s '%s'" % (a, args[i + 1]))
                i += 2
            else:
                parts.append(a)
                i += 1
        body = ("$ProgressPreference='SilentlyContinue';"
                "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8;"
                "$OutputEncoding=[System.Text.Encoding]::UTF8;"
                "& '%s' %s" % (ps1, " ".join(parts)))
        ps = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"),
                          "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
        if not os.path.isfile(ps):
            ps = "powershell.exe"
        return [ps, "-NoProfile", "-NoLogo", "-ExecutionPolicy", "Bypass",
                "-Command", body]

    def start(self, key):
        if self.busy:
            return
        name, base_args, need_admin, confirm = self.ACTIONS[key]
        args = list(base_args)
        if key != "rollback":
            args += ["-Role", self.role]

        if need_admin and not self.admin:
            if self.ask("需要管理员权限",
                        "“%s”会写入 HKLM 策略键。当前是普通用户，这些项会被自动跳过。\n\n"
                        "是否以管理员身份重新打开本工具？" % name,
                        ok_text="以管理员重开"):
                if elevate_self():
                    self.root.destroy()
                else:
                    self._set_status("提权被取消", "warn")
                return
            self.logln("")
            self.logln(">> 以当前权限继续，HKLM 项将被跳过", "warn")

        if confirm == "l2":
            if not self.ask("应用 L1 + L2",
                            "L2 含：台式机切高性能电源、全 SSD 禁 SysMain、"
                            "系统盘紧张时执行组件清理（DISM 可能耗时数分钟）。\n\n"
                            "笔记本自动跳过电源项，非全 SSD 自动跳过 SysMain。",
                            ok_text="确认执行"):
                return
        if confirm == "rb":
            mf = latest_manifest()
            if not mf:
                self.logln("")
                self.logln(">> 未找到变更清单，无可回滚内容（%s）" % BACKUP_DIR, "warn")
                self._set_status("没有可回滚的变更", "warn")
                return
            if not self.ask("回滚确认",
                            "将按清单 %s 逆序还原。\n\n"
                            "本次新建的注册表键会被整键删除；界面相关项需重新登录生效。"
                            % mf, ok_text="确认回滚", danger=True):
                return

        cmd = self._build_ps(args)
        if cmd is None:
            self.logln(">> 找不到内置脚本 %s" % PS1_NAME, "error")
            self._set_status("内置脚本缺失，EXE 可能已损坏", "err")
            return

        role_name = dict((k, n) for k, n, _ in ROLES)[self.role]
        self.logln("")
        self.logln(">> %s    机型：%s    %s" % (
            name, role_name if key != "rollback" else "-",
            "管理员" if self.admin else "普通用户"), "meta")

        self._enter_busy()
        threading.Thread(target=self._worker, args=(cmd,), daemon=True).start()
        self.root.after(60, self._poll)

    def _enter_busy(self):
        self.busy = True
        for b in (self.btn_report, self.btn_dry, self.btn_l1, self.btn_l2,
                  self.btn_rollback, self.btn_boundary):
            b.configure(state="disabled")
        for b in self.seg_btns.values():
            b.configure(state="disabled")
        self.btn_stop.configure(state="normal")
        self.progress.pack(side="left", padx=(0, self.px(10)))
        self.btn_stop.pack(side="left")
        self.progress.start(14)
        self._set_status("执行中…", "run")

    def _leave_busy(self):
        self.busy = False
        for b in (self.btn_report, self.btn_dry, self.btn_l1, self.btn_l2,
                  self.btn_rollback, self.btn_boundary):
            b.configure(state="normal")
        for b in self.seg_btns.values():
            b.configure(state="normal")
        self.progress.stop()
        self.progress.pack_forget()
        self.btn_stop.pack_forget()
        self.btn_stop.configure(state="disabled")

    def _worker(self, cmd):
        try:
            self.proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL, creationflags=CREATE_NO_WINDOW)
            for raw in iter(self.proc.stdout.readline, b""):
                if raw:
                    self.q.put(("line", smart_decode(raw).rstrip("\r\n")))
            self.proc.stdout.close()
            code = self.proc.wait()
            self.q.put(("done", code))
        except Exception as exc:
            self.q.put(("line", "[ERROR] 无法启动 PowerShell：%s" % exc))
            self.q.put(("done", -1))

    def _poll(self):
        try:
            while True:
                kind, payload = self.q.get_nowait()
                if kind == "line":
                    self.logln(payload, self._guess_tag(payload))
                elif kind == "done":
                    self._finish(payload)
                    return
        except queue.Empty:
            pass
        except Exception:
            pass
        if self.busy:
            self.root.after(70, self._poll)

    def _guess_tag(self, line):
        head = line[:9]
        if "[OK" in head:
            return "ok"
        if "[WARN" in head:
            return "warn"
        if "[ERROR" in head:
            return "error"
        if "[SKIP" in head:
            return "skip"
        if line.startswith(">>"):
            return "meta"
        return "info"

    def _finish(self, code):
        self._leave_busy()
        if code == 0:
            self._set_status("完成（退出码 0）", "ok")
            self.logln(">> 完成", "ok")
        else:
            self._set_status("结束，退出码 %d" % code, "err")
            self.logln(">> 结束，退出码 %d" % code, "error")
        mf = latest_manifest()
        if mf:
            self.logln(">> 当前清单：%s" % mf, "skip")
        self._refresh_manifest_card()

    def stop(self):
        if not self.busy or self.proc is None:
            return
        if not self.ask("停止执行",
                        "强制终止可能让 DISM 等操作停留在中间状态。\n"
                        "若已产生变更清单，可用「回滚最近一次变更」恢复。",
                        ok_text="确认停止", danger=True):
            return
        try:
            self.proc.terminate()
            self.logln(">> 已请求终止", "warn")
        except Exception as exc:
            self.logln(">> 终止失败：%s" % exc, "error")


def main():
    enable_dpi()
    root = tk.Tk()
    try:
        App(root)
    except Exception:
        try:
            import tkinter.messagebox as mb
            mb.showerror(APP_NAME, "启动失败：\n\n%s" % traceback.format_exc())
        except Exception:
            pass
        return 1
    root.mainloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())

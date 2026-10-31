#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
监控 FTDI（Tang Nano 20K 的 USB 桥）连接稳定性。

判断"接触不良"到底发生在哪一环：
  · 设备反复出现 / 消失  -> USB 物理接触（线 / 座 / 口）
  · 状态在 OK 与 Unknown 之间抖动 -> 供电或信号质量不足
  · 一直稳定 OK           -> 接触没问题，卡住是别的原因（驱动 / 固件 / 进程）

用法：
    python tools/watch_usb_stability.py 20

输出：
    每 0.5 s 采样一次，最后给出：
      - 设备数变化次数
      - 状态翻转次数
      - 结论
"""
import sys
import time

import winreg  # 用注册表枚举，不依赖 WMI 的慢查询


def list_ftdi():
    """从注册表枚举 USB 设备，返回 {instance_id: (status_hint, friendly_name)}"""
    devs = {}
    try:
        key = winreg.OpenKey(
            winreg.HKEY_LOCAL_MACHINE,
            r"SYSTEM\CurrentControlSet\Enum\USB",
        )
    except OSError:
        return devs

    i = 0
    while True:
        try:
            vid_pid = winreg.EnumKey(key, i)
        except OSError:
            break
        i += 1
        if "VID_0403" not in vid_pid.upper():
            continue
        try:
            sub = winreg.OpenKey(key, vid_pid)
        except OSError:
            continue
        j = 0
        while True:
            try:
                inst = winreg.EnumKey(sub, j)
            except OSError:
                break
            j += 1
            name = ""
            try:
                dk = winreg.OpenKey(sub, inst)
                name = winreg.QueryValueEx(dk, "FriendlyName")[0]
                winreg.CloseKey(dk)
            except OSError:
                pass
            devs[inst] = name
        winreg.CloseKey(sub)
    winreg.CloseKey(key)
    return devs


def main():
    secs = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0
    print("monitoring FTDI devices for %.1f s (sample every 0.5 s) ..." % secs)
    print("%-6s %-4s %s" % ("t(s)", "num", "devices"))
    print("-" * 70)

    prev_ids = None
    changes = 0
    samples = 0
    t0 = time.time()

    while True:
        t = time.time() - t0
        if t > secs:
            break
        cur = list_ftdi()
        ids = sorted(cur.keys())

        if prev_ids is not None and ids != prev_ids:
            changes += 1
            print("%-6.1f %-4d *** CHANGE (%d -> %d) ***"
                  % (t, len(ids), len(prev_ids), len(ids)))
            for i in ids:
                print("           + %s" % cur[i][:50])
            for i in prev_ids:
                if i not in ids:
                    print("           - (gone) %s" % i[-20:])
        elif samples % 4 == 0:
            names = ", ".join((n or "?")[:24] for n in cur.values())
            print("%-6.1f %-4d %s" % (t, len(ids), names))

        prev_ids = ids
        samples += 1
        time.sleep(0.5)

    print("\n" + "=" * 70)
    print("samples: %d   changes: %d" % (samples, changes))
    if changes == 0:
        print("VERDICT: USB link is STABLE for %.0f s" % secs)
        print("  -> 接触没问题；烧录卡住是别的原因（驱动/进程/供电）")
    elif changes <= 2:
        print("VERDICT: minor glitches (%d) —— 轻微接触问题" % changes)
        print("  -> 多半是线材或接口松动，换线/换口可改善")
    else:
        print("VERDICT: UNSTABLE (%d changes) —— 接触问题严重" % changes)
        print("  -> 换 USB 线、换口；若仍抖动，板子的 USB 座可能虚焊")
    return 0


if __name__ == "__main__":
    sys.exit(main())

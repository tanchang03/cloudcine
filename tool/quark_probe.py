#!/usr/bin/env python3
"""夸克接口探针 —— 在 Mac 上先把真实响应形状拿下来，再照着写 Kotlin。

为什么要有这个脚本（而不是直接在 Android 上试）：
  真机上的迭代成本是「改 Kotlin → gradle 构建 → adb install → 看 logcat」，
  一轮好几分钟；而这里改一行、跑一次是秒级。**API 形状这种一次性的东西
  不值得在真机上试错。**

流程（与 lib/data/auth/quark_qr_login.dart 完全一致，那条链路 2026-09-24 真机跑通）：
  1. GET https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin?client_id=532
  2. 把 token 装进二维码，用户用夸克 App 扫
  3. GET https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken?token=…&client_id=532
  4. GET https://pan.quark.cn/account/info?st=<ticket>  → Set-Cookie 里下发 __pus
  5. 页面导航语义补一跳（Accept: text/html）拿 __puus

拿到 Cookie 后落盘到 .quark_probe/cookie.json，后续探针直接复用，
不必每次重新扫码。

用法：
    python tool/quark_probe.py login     # 出二维码，扫码
    python tool/quark_probe.py list      # 列根目录
    python tool/quark_probe.py play <fid>  # 看 play/info 与 audioplay 的真实形状
"""

import json
import os
import sys
import time
import urllib.parse
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / ".quark_probe"
# ⛔ 不能用 `mkdir(exist_ok=True)`：本机沙箱的 mkdir 代理不认 exist_ok，
#    目录已存在时直接抛 PermissionError: EEXIST（看起来像权限问题，其实是幂等没实现）。
if not OUT.exists():
    OUT.mkdir(parents=True)
COOKIE_FILE = OUT / "cookie.json"

# ⛔ 必须绕开本机代理：代理会把请求劫持走，扫码登录与网盘接口都会失败。
SESSION = requests.Session()
SESSION.trust_env = False
SESSION.proxies = {"http": None, "https": None}

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)

CAS = "https://uop.quark.cn"
CLIENT_ID = "532"
QR_BIZ_STR = (
    "S%3Acustom%7COPT%3ASAREA%400%7COPT%3AIMMERSIVE%401"
    "%7COPT%3ABACK_BTN_STYLE%400"
)

PC = "https://drive-pc.quark.cn"
COMMON_PARAMS = {"pr": "ucpro", "fr": "pc"}

# 与 quark_endpoints.dart 的 knownCookieNames 同名单。
# ⛔ Video-Auth 不能少 —— 转码档的 m3u8 地址不带签名，鉴权全靠它。
KNOWN_COOKIES = [
    "__pus", "__puus", "__kuus", "__uid", "__kp",
    "__kps", "__ktd", "__kui", "Video-Auth",
]


def log(*a):
    print(*a, flush=True)


def save_cookie(cookies: dict):
    COOKIE_FILE.write_text(json.dumps(cookies, ensure_ascii=False, indent=2))
    log(f"  → Cookie 已存 {COOKIE_FILE}（键={sorted(cookies)}）")


def load_cookie() -> dict:
    if not COOKIE_FILE.exists():
        log("没有 cookie，先跑 login")
        sys.exit(1)
    return json.loads(COOKIE_FILE.read_text())


def cookie_header(cookies: dict) -> str:
    return "; ".join(f"{k}={v}" for k, v in cookies.items() if v)


# ----------------------------------------------------------------------
# 扫码登录
# ----------------------------------------------------------------------

def cmd_login():
    import qrcode

    h = {"Accept": "application/json, text/plain, */*", "User-Agent": UA,
         "Referer": "https://pan.quark.cn/"}

    r = SESSION.get(f"{CAS}/cas/ajax/getTokenForQrcodeLogin",
                    params={"client_id": CLIENT_ID}, headers=h, timeout=15)
    j = r.json()
    token = (j.get("data") or {}).get("members", {}).get("token")
    if not token:
        log("取 token 失败：", json.dumps(j, ensure_ascii=False)[:400])
        sys.exit(1)
    log(f"token 已取到（{token[:8]}…）")

    qr_url = (
        f"https://su.quark.cn/4_eMHBJ?uc_param_str="
        f"&token={urllib.parse.quote(token)}"
        f"&client_id={CLIENT_ID}"
        f"&uc_biz_str={QR_BIZ_STR}"
        f"&platform=mac"
    )
    img = qrcode.make(qr_url)
    png = OUT / "qrcode.png"
    img.save(png)
    log(f"二维码已写到 {png}")

    # 把二维码也渲染成终端可读的字符画，方便没有图片查看器时直接扫。
    q = qrcode.QRCode(border=1)
    q.add_data(qr_url)
    q.make()
    q.print_ascii(invert=True)

    log("请用手机夸克 App 扫码并在手机上确认……（最多等 180 秒）")
    deadline = time.time() + 180
    ticket = None
    while time.time() < deadline:
        rr = SESSION.get(f"{CAS}/cas/ajax/getServiceTicketByQrcodeToken",
                         params={"token": token, "client_id": CLIENT_ID},
                         headers=h, timeout=15)
        jj = rr.json()
        st = jj.get("status")
        if st == 2000000:
            ticket = (jj.get("data") or {}).get("members", {}).get("service_ticket")
            log("扫码已确认，拿到 service_ticket")
            break
        if st == 50004001:
            time.sleep(2)
            continue
        log(f"轮询异常 status={st} msg={jj.get('message')}")
        time.sleep(2)

    if not ticket:
        log("超时未扫码")
        sys.exit(1)

    # ---- 第 4 跳：票据 → 账号 Cookie ----
    h2 = {"Accept": "application/json, text/plain, */*", "User-Agent": UA,
          "Referer": "https://pan.quark.cn/"}
    r2 = SESSION.get("https://pan.quark.cn/account/info",
                     params={"st": ticket}, headers=h2, timeout=15)
    log(f"/account/info → HTTP {r2.status_code} success={r2.json().get('success')}")
    cookies = {k: v for k, v in r2.cookies.items()}
    log(f"  下发 cookie 键={sorted(cookies)}")

    # ---- 补一跳（页面导航语义）拿 __puus ----
    if not cookies.get("__puus"):
        nav = {
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "User-Agent": UA, "Referer": "https://pan.quark.cn/",
            "Cookie": cookie_header(cookies),
        }
        for home in ("https://pan.quark.cn/list/all", "https://pan.quark.cn/"):
            rh = SESSION.get(home, headers=nav, timeout=15)
            new = {k: v for k, v in rh.cookies.items()}
            log(f"  补跳 {home} → HTTP {rh.status_code} 新增={sorted(new)}")
            cookies.update(new)
            nav["Cookie"] = cookie_header(cookies)
            if cookies.get("__puus"):
                break

    if not cookies.get("__pus"):
        log("⛔ 没拿到 __pus，登录失败")
        sys.exit(1)
    save_cookie(cookies)
    log("登录完成。")


# ----------------------------------------------------------------------
# 网盘接口
# ----------------------------------------------------------------------

def api_headers(cookies: dict) -> dict:
    return {
        "Accept": "application/json, text/plain, */*",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "User-Agent": UA,
        "Referer": "https://pan.quark.cn/",
        "Origin": "https://pan.quark.cn",
        "Cookie": cookie_header(cookies),
    }


def dump(path: str, obj, limit: int = 4000):
    (OUT / path).write_text(json.dumps(obj, ensure_ascii=False, indent=2))
    log(f"  → 落盘 {OUT / path}")


def cmd_list(fid: str = "0"):
    cookies = load_cookie()
    h = api_headers(cookies)
    p = dict(COMMON_PARAMS)
    p.update({"_page": 1, "_size": 50, "_fetch_total": 1,
              "_sort": "file_type:asc,updated_at:desc", "_is_hl": 1, "pdir_fid": fid})
    r = SESSION.get(f"{PC}/1/clouddrive/file/sort", params=p, headers=h, timeout=20)
    j = r.json()
    log(f"file/sort → HTTP {r.status_code} code={j.get('code')} msg={j.get('message')}")
    items = ((j.get("data") or {}).get("list") or [])
    log(f"  条目 {len(items)} 条；data 的键={(j.get('data') or {}).keys()}")
    for it in items[:15]:
        log(f"    dir={it.get('dir')} type={it.get('file_type')} "
            f"size={it.get('size')} {it.get('file_name')}  fid={str(it.get('fid'))[:12]}…")
    dump("file_sort.json", j)


def cmd_play(fid: str):
    cookies = load_cookie()
    h = api_headers(cookies)

    # ---- ① 转码阶梯：唯一能拿到清晰度列表的路由 ----
    body = {
        "resolutions": "normal,low,high,super,2k,4k",
        "fetch_credits_setting": 1,
        "fetch_play_video_resolution_setting": 1,
        "fetch_play_audio_type_setting": 1,
        "support_resolution_free_limit_ab": 1,
        "fetch_pdir": 1,
        "support_right": "trial_1080P_zhizhen_pc",
        "supports": "",
        "fids": [fid],
    }
    r = SESSION.post(f"{PC}/1/clouddrive/batch/file/play/info",
                     params={**COMMON_PARAMS, "uc_param_str": "utfrpr"},
                     json=body, headers={**h, "Content-Type": "application/json"}, timeout=25)
    j = r.json()
    log(f"play/info → HTTP {r.status_code} code={j.get('code')} msg={j.get('message')}")
    dump("play_info.json", j)

    data = j.get("data") or {}
    node = data.get(fid) if isinstance(data, dict) else None
    if node is None and isinstance(data, list) and data:
        node = data[0]
    if isinstance(node, dict):
        log(f"  节点键={sorted(node.keys())}")
        for key in ("video_list", "audio_list"):
            lst = node.get(key) or []
            log(f"  {key}: {len(lst)} 条")
            for v in lst:
                info = v.get("video_info") or v.get("audio_info") or {}
                log(f"    resolution={v.get('resolution')} "
                    f"w×h={info.get('width')}×{info.get('height')} "
                    f"bitrate={info.get('bitrate')} size={info.get('size')}")
                url = info.get("url") or ""
                log(f"      url={url[:150]}")
        meta = node.get("meta")
        if meta:
            log(f"  meta={json.dumps(meta, ensure_ascii=False)[:300]}")
    # 顺带把 Video-Auth 记下来 —— 转码档全靠它
    va = r.cookies.get("Video-Auth")
    if va:
        log(f"  ★ 响应下发 Video-Auth={va[:20]}…")
        cookies["Video-Auth"] = va
        save_cookie(cookies)

    # ---- ② 原画：原文件本身（单连接直连） ----
    r2 = SESSION.get(f"{PC}/1/clouddrive/file/audioplay", params={**COMMON_PARAMS, "fid": fid},
                     headers=h, timeout=20)
    j2 = r2.json()
    log(f"audioplay → HTTP {r2.status_code} code={j2.get('code')} msg={j2.get('message')}")
    d2 = j2.get("data") or {}
    if isinstance(d2, dict):
        log(f"  data 键={sorted(d2.keys())}")
        log(f"  size={d2.get('size')} format_type={d2.get('format_type')} "
            f"duration={d2.get('duration')}")
        log(f"  audio_url={str(d2.get('audio_url'))[:150]}")
    dump("audioplay.json", j2)

    # ---- ③ 实测直连带宽（决定 4K 能不能只靠单连接） ----
    url = (d2 or {}).get("audio_url")
    if url:
        log(f"  直链主机={urllib.parse.urlparse(url).netloc} 路径={urllib.parse.urlparse(url).path[:60]}")
        log(f"  发请求时带的 Cookie 键={[c.split('=')[0] for c in cookie_header(cookies).split('; ')]}")
        log("  实测原画单连接带宽（下 30 MiB 或 8 秒）…")
        t0 = time.time()
        got = 0
        try:
            with SESSION.get(url, headers={"Range": "bytes=0-31457279",
                                           "Cookie": cookie_header(cookies),
                                           "User-Agent": UA},
                             stream=True, timeout=20) as rs:
                log(f"  HTTP {rs.status_code} content-length={rs.headers.get('content-length')} "
                    f"content-range={rs.headers.get('content-range')}")
                if rs.status_code >= 400:
                    log(f"  响应体：{rs.text[:300]}")
                for chunk in rs.iter_content(256 * 1024):
                    got += len(chunk)
                    if time.time() - t0 > 8:
                        break
        except Exception as e:  # noqa: BLE001
            log(f"  下载中断：{e}")
        dt = time.time() - t0
        if dt > 0:
            log(f"  ★ 单连接实测 {got / 1048576:.2f} MiB / {dt:.2f}s "
                f"= {got / 1048576 / dt:.2f} MiB/s")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "login"
    if cmd == "login":
        cmd_login()
    elif cmd == "list":
        cmd_list(sys.argv[2] if len(sys.argv) > 2 else "0")
    elif cmd == "play":
        cmd_play(sys.argv[2])
    else:
        log(__doc__)

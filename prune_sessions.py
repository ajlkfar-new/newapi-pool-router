#!/usr/bin/env python3
"""删除 New API 中长期闲置的登录会话（补上游清理能力的缺口）。

背景
----
New API 自带 service/auth_cleanup.go，每小时清理一次，但它只删
``expires_at < now`` 的会话（即**已过期**）。而会话有效期
``LoginSessionTTL = 30 天``（service/auth_token.go），因此"登录过但长期没用"的
会话在 30 天内始终占着 active 名额，单账号反复登录就会累积到上限。

本脚本删除 ``last_active_at`` 早于 N 天的**活跃**会话，让它们不再占用名额。

安全边界
--------
- 只动 UserSession 表（按表名自动探测，兼容大小写/前缀差异）。
- 只删 status='active' 且 last_active_at 明显陈旧的记录；最近用过的会话一律保留，
  因此不会把正在使用的登录踢下线。
- 表不存在（例如尚未有人登录过）时静默跳过，不报错、不阻塞启动。
"""
from __future__ import annotations

import os
import sys
from datetime import datetime, timezone

IDLE_DAYS = int(os.getenv("SESSION_IDLE_DAYS", "14"))
TABLE_HINTS = ("user_sessions", "user_session")

# 按优先级尝试的列候选（兼容命名差异）
COL_SID = ("sid", "id")
COL_STATUS = ("status",)
COL_LAST = ("last_active_at", "last_active", "updated_at", "created_at")
COL_EXPIRES = ("expires_at",)


def log(msg: str) -> None:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    print(f"[prune_sessions] {ts} {msg}", flush=True)


def main() -> int:
    dsn = os.getenv("SQL_DSN", "").strip()
    if not dsn:
        log("SQL_DSN 未设置，跳过（本实例可能用 SQLite）")
        return 0

    try:
        import psycopg2
    except ImportError:
        log("psycopg2 不可用，跳过")
        return 0

    try:
        conn = psycopg2.connect(dsn, connect_timeout=15)
    except Exception as exc:  # noqa: BLE001
        log(f"连库失败，跳过本轮：{exc}")
        return 0

    try:
        conn.autocommit = True
        with conn.cursor() as cur:
            table = _find_table(cur)
            if not table:
                log("未找到会话表，跳过")
                return 0

            cols = _table_columns(cur, table)
            sid_col = _pick(cols, COL_SID)
            status_col = _pick(cols, COL_STATUS)
            last_col = _pick(cols, COL_LAST)
            if not (sid_col and last_col):
                log(f"{table} 缺少必要列(sid={sid_col}, last={last_col})，跳过")
                return 0

            cutoff = int(datetime.now(timezone.utc).timestamp()) - IDLE_DAYS * 86400

            where = [f'"{last_col}" < %s']
            params: list[object] = [cutoff]
            if status_col:
                where.append(f'"{status_col}" = %s')
                params.append("active")
            if _pick(cols, COL_EXPIRES):
                expire_col = _pick(cols, COL_EXPIRES)
                # 仅处理尚未过期的（已过期的交给 New API 自己的清理）
                where.append(f'"{expire_col}" >= %s')
                params.append(int(datetime.now(timezone.utc).timestamp()))

            sql_count = f'SELECT COUNT(*) FROM "{table}" WHERE ' + " AND ".join(where)
            cur.execute(sql_count, params)
            n = cur.fetchone()[0]
            if not n:
                log(f"无需清理（闲置阈值 {IDLE_DAYS} 天）")
                return 0

            sql_del = f'DELETE FROM "{table}" WHERE ' + " AND ".join(where)
            cur.execute(sql_del, params)
            log(f"已清理 {n} 条闲置会话（last_active_at 早于 {IDLE_DAYS} 天前）")
    except Exception as exc:  # noqa: BLE001
        log(f"清理失败，跳过本轮：{exc}")
    finally:
        conn.close()

    return 0


def _find_table(cur) -> str | None:
    """在 public schema 里找会话表，精确名优先，其次后缀匹配。"""
    cur.execute(
        "SELECT table_name FROM information_schema.tables "
        "WHERE table_schema = 'public'"
    )
    names = [r[0] for r in cur.fetchall()]
    lowered = {n.lower(): n for n in names}
    for hint in TABLE_HINTS:
        if hint in lowered:
            return lowered[hint]
    for n in names:
        low = n.lower()
        if any(low.endswith(suffix) for suffix in TABLE_HINTS):
            return n
    return None


def _table_columns(cur, table: str) -> set[str]:
    cur.execute(
        "SELECT column_name FROM information_schema.columns "
        "WHERE table_schema = 'public' AND table_name = %s",
        (table,),
    )
    return {r[0].lower() for r in cur.fetchall()}


def _pick(available: set[str], candidates: tuple[str, ...]) -> str | None:
    for c in candidates:
        if c in available:
            return c
    return None


if __name__ == "__main__":
    sys.exit(main())

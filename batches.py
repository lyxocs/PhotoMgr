import logging
import os
import re
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from threading import Lock
from uuid import uuid4

from photo_review import DATA, load_json, scan, score, write_json

BATCHES = DATA / "batches"
ACTIVE = {}
LOCK = Lock()
QUEUE = ThreadPoolExecutor(max_workers=1)
LEGACY = "legacy"


def batch_data(batch_id):
    if batch_id == LEGACY:
        return DATA
    if not isinstance(batch_id, str) or not re.fullmatch(r"[a-f0-9]{32}", batch_id):
        raise ValueError("批次无效")
    path = BATCHES / batch_id
    if not (path / "batch.json").is_file():
        raise ValueError("找不到这个批次")
    return path


def list_batches():
    results = []
    with LOCK:
        for folder in sorted(BATCHES.glob("*/batch.json"), key=lambda path: path.stat().st_ctime, reverse=True):
            item = load_json(folder, {})
            results.append({"id": folder.parent.name, "source": item["source"]})
    legacy = load_json(DATA / "project.json", {})
    if legacy.get("source"):
        results.append({"id": LEGACY, "source": legacy["source"]})
    return results


def batch_status(batch_id, data):
    with LOCK:
        state = load_json(data / "batch.json", {})
        if state.get("phase") in {"queued", "scanning", "grouping", "scoring"} and batch_id not in ACTIVE:
            state["phase"] = "interrupted"
        return state


def run_batch(batch_id, data, state, key):
    def progress(phase, done, total, message=""):
        state.update(phase=phase, done=done, total=total, message=message)
        write_json(data / "batch.json", state)

    phase, message = "complete", ""
    try:
        project = load_json(data / "project.json", None)
        if not project or not project["groups"]:
            source = Path(state["source"])
            if not source.is_dir():
                raise ValueError("找不到源文件夹，请检查磁盘是否已连接")
            project = scan(source, data, progress)
        if project["groups"]:
            failures = score(project, key, data, progress)
            if failures:
                phase, message = "error", f"{failures} 个评分任务失败，可续跑"
        else:
            phase, message = "error", "没有可读取的 JPG/JPEG 照片"
    except Exception:
        logging.exception("Photo batch %s failed", batch_id)
        phase, message = "error", "处理失败，请检查照片目录或 TokenLink 配置后重试"
    finally:
        with LOCK:
            try:
                progress(phase, state["done"], state["total"], message)
            finally:
                ACTIVE.pop(batch_id, None)


def enqueue(payload):
    key = payload.get("key") or os.environ.get("TOKENLINK_API_KEY", "")
    if not isinstance(key, str) or not key.strip():
        raise ValueError("请输入 TokenLink API Key")
    batch_id = payload.get("batch")
    with LOCK:
        if batch_id is None:
            source = payload.get("source")
            if not isinstance(source, str) or not source.strip():
                raise ValueError("请选择照片文件夹")
            source = Path(source.strip()).expanduser().resolve(strict=True)
            if not source.is_dir():
                raise ValueError("请选择文件夹")
            project_root = DATA.parent
            if source.is_relative_to(project_root):
                raise ValueError("请选择程序目录以外的照片文件夹")
            batch_id = uuid4().hex
            data = BATCHES / batch_id
            data.mkdir(parents=True)
            state = {"source": str(source), "created": datetime.now().isoformat(timespec="seconds")}
        else:
            data = batch_data(batch_id)
            if batch_id in ACTIVE:
                return batch_id
            state = load_json(data / "batch.json", {})
            if batch_id == LEGACY and "source" not in state:
                project = load_json(data / "project.json", {})
                state["source"] = project["source"]
        state.update(phase="queued", done=0, total=0, message="")
        write_json(data / "batch.json", state)
        ACTIVE[batch_id] = QUEUE.submit(run_batch, batch_id, data, state, key.strip())
    return batch_id


def folder_contents(raw_path):
    if not raw_path:
        return {"path": "", "parent": "", "folders": [
            {"name": drive, "path": drive} for drive in os.listdrives()
        ]}
    path = Path(raw_path).resolve(strict=True)
    folders = sorted((entry for entry in path.iterdir() if entry.is_dir()),
                     key=lambda entry: entry.name.casefold())
    return {"path": str(path), "parent": str(path.parent) if path.parent != path else "",
            "folders": [{"name": entry.name, "path": str(entry)} for entry in folders]}

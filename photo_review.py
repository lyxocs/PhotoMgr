from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import math
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path
from tempfile import NamedTemporaryFile

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / ".deps"))
from PIL import Image, ImageDraw, ImageEnhance, ImageOps, ImageStat

DATA = ROOT / ".data"
PREVIEWS = DATA / "preview"
WEIGHTS = {"composition": 25, "light": 20, "moment": 25, "technical": 15, "impact": 15}
ENDPOINT = "https://tokenlink.woa.com/openapi/v1/chat/completions"
MODEL = "hy4"
REVISION = "2026-11-v2"


def write_json(path, value):
    with NamedTemporaryFile(dir=path.parent, delete=False, encoding="utf-8", mode="w") as output:
        temporary = Path(output.name)
    try:
        temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
        for attempt in range(5):
            try:
                temporary.replace(path)
                break
            except PermissionError:
                if attempt == 4:
                    raise
                time.sleep(0.04 * (attempt + 1))
    finally:
        temporary.unlink(missing_ok=True)


def load_json(path, default):
    for attempt in range(5):
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return default
        except PermissionError:
            if attempt == 4:
                raise
            time.sleep(0.04 * (attempt + 1))


def prepare(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    photo_id = digest.hexdigest()
    with Image.open(path) as original:
        raw_date = original.getexif().get_ifd(34665).get(36867)
        try:
            captured = datetime.strptime(raw_date, "%Y:%m:%d %H:%M:%S").isoformat()
        except (TypeError, ValueError):
            captured = None
        profile = original.info.get("icc_profile")
        photo = ImageOps.exif_transpose(original).convert("RGB")
        photo.thumbnail((1200, 1200))
        preview = PREVIEWS / f"{photo_id}.jpg"
        if not preview.exists():
            with NamedTemporaryFile(dir=PREVIEWS, delete=False) as output:
                temporary = Path(output.name)
            try:
                photo.save(temporary, format="JPEG", quality=86, icc_profile=profile)
                try:
                    temporary.replace(preview)
                except PermissionError:
                    if not preview.exists():
                        raise
            finally:
                temporary.unlink(missing_ok=True)
        small = photo.resize((16, 16), Image.Resampling.LANCZOS)
        pixels = tuple(small.get_flattened_data())
        gray = list(photo.convert("L").resize((9, 8), Image.Resampling.LANCZOS).get_flattened_data())
        edges = tuple(gray[y * 9 + x] > gray[y * 9 + x + 1] for y in range(8) for x in range(8))
        return {"id": photo_id, "name": path.name, "file": str(path), "captured": captured,
                "width": photo.width, "height": photo.height, "duplicates": []}, pixels, edges


def distance(left, right):
    _, left_pixels, left_edges = left
    _, right_pixels, right_edges = right
    color = sum(abs(a - b) for p, q in zip(left_pixels, right_pixels) for a, b in zip(p, q)) / (256 * 3 * 255)
    structure = sum(a != b for a, b in zip(left_edges, right_edges)) / 64
    return 0.72 * color + 0.28 * structure


def position(photo):
    match = re.search(r"_(\d+)$", Path(photo["name"]).stem)
    return int(match[1]) if match else None


def group_photos(records):
    # Complete linkage prevents a chain of borderline matches from merging distinct scenes.
    groups = [[i] for i in range(len(records))]
    distances = {}
    for i, left in enumerate(records):
        for j in range(i):
            right = records[j]
            d = distance(left, right)
            a, b = left[0], right[0]
            p, q = position(a), position(b)
            nearby = p is not None and q is not None and abs(p - q) <= 5
            if a["captured"] and b["captured"]:
                gap = abs((datetime.fromisoformat(a["captured"]) - datetime.fromisoformat(b["captured"])).total_seconds())
                nearby = nearby or gap <= 4
            same_orientation = (a["width"] >= a["height"]) == (b["width"] >= b["height"])
            limit = (0.190 if nearby else 0.148) if same_orientation else 0.095
            distances[j, i] = d / limit
    while True:
        candidates = (
            (max(distances[min(a, b), max(a, b)] for a in left for b in right), j, i)
            for i, right in enumerate(groups) for j, left in enumerate(groups[:i])
        )
        value, left, right = min(candidates, default=(math.inf, 0, 0))
        if value > 1:
            break
        groups[left] = sorted(groups[left] + groups.pop(right))
    return [[records[i][0] for i in group] for group in groups]


def read_photo(path):
    try:
        return prepare(path), None
    except (OSError, ValueError) as exc:
        return None, str(exc)


def scan(source, data=DATA, progress=None):
    PREVIEWS.mkdir(parents=True, exist_ok=True)
    paths = []
    for folder, directories, files in source.walk():
        # A parent folder may contain this application and its generated JPEGs.
        directories[:] = [name for name in directories if folder / name != ROOT]
        paths.extend(folder / name for name in files if Path(name).suffix.lower() in {".jpg", ".jpeg"})
    paths.sort(key=lambda p: (re.sub(r"\(\d+\)$", "", p.stem).casefold(),
                              "(" in p.stem, str(p).casefold()))
    records, errors = {}, []
    if progress:
        progress("scanning", 0, len(paths))
    with ThreadPoolExecutor(max_workers=4) as executor:
        for index, (path, result) in enumerate(zip(paths, executor.map(read_photo, paths, buffersize=12)), 1):
            record, error = result
            if progress and (index % 5 == 0 or index == len(paths)):
                progress("scanning", index, len(paths))
            if error is not None:
                errors.append({"file": str(path), "error": error})
                continue
            photo = record[0]
            if photo["id"] in records:
                records[photo["id"]][0]["duplicates"].append({"name": photo["name"], "file": photo["file"]})
            else:
                records[photo["id"]] = record
    if progress:
        progress("grouping", 0, len(records))
    groups = [{"id": index, "photos": photos} for index, photos in enumerate(group_photos(list(records.values())), 1)]
    project = {"source": str(source), "input_count": len(paths), "errors": errors, "groups": groups}
    write_json(data / "project.json", project)
    print(f"Scanned {len(paths)} files, {len(records)} unique, {len(groups)} groups, {len(errors)} errors", flush=True)
    for group in groups:
        print(group["id"], " ".join(photo["name"] for photo in group["photos"]), flush=True)
    return project


class ContentFiltered(ValueError):
    pass


def request_vision(key, prompt, picture):
    data_url = "data:image/jpeg;base64," + base64.b64encode(picture).decode("ascii")
    payload = {"model": MODEL, "stream": True, "max_tokens": 8500, "messages": [
        {"role": "user", "content": [{"type": "text", "text": prompt},
                                     {"type": "image_url", "image_url": {"url": data_url}}]}
    ]}
    request = urllib.request.Request(ENDPOINT, json.dumps(payload).encode("utf-8"),
                                     {"Authorization": f"Bearer {key}", "Content-Type": "application/json",
                                      "Accept": "text/event-stream"})
    chunks = []
    finish = None
    with urllib.request.urlopen(request, timeout=110) as response:
        for line in response:
            if not line.startswith(b"data:"):
                continue
            body = line[5:].strip()
            if body == b"[DONE]":
                break
            event = json.loads(body)
            if event.get("error"):
                raise ValueError("TokenLink returned a stream error")
            for choice in event.get("choices", []):
                chunks.append(choice.get("delta", {}).get("content") or "")
                finish = choice.get("finish_reason") or finish
    if finish == "content_filter":
        raise ContentFiltered("TokenLink content filter")
    answer = "".join(chunks)
    start, end = answer.find("{"), answer.rfind("}")
    if start < 0 or end < start:
        raise ValueError(f"hy4 response did not contain JSON (finish: {finish})")
    return json.loads(answer[start:end + 1])


def contact_sheet(photos):
    columns = min(2, len(photos))
    rows = math.ceil(len(photos) / columns)
    sheet = Image.new("RGB", (columns * 620, rows * 570), "#292b2e")
    draw = ImageDraw.Draw(sheet)
    for index, photo in enumerate(photos):
        with Image.open(PREVIEWS / f"{photo['id']}.jpg") as picture:
            picture.thumbnail((596, 519))
            x, y = (index % columns) * 620, (index // columns) * 570
            sheet.paste(picture, (x + (620 - picture.width) // 2, y + 10 + (519 - picture.height) // 2))
            draw.text((x + 19, y + 533), str(index + 1), fill="white", font_size=29)
    buffer = io.BytesIO()
    sheet.save(buffer, format="JPEG", quality=87)
    return buffer.getvalue()


PROMPT = """你是越野跑活动的摄影选片师。拼图里的每张照片都有独立编号。请逐张给 0 到 10 的绝对分（允许一位小数），同组比较表情、姿态、动作时机和构图。7 分良好，8 分优秀，9 分是少数作品级照片。允许整组一张也不推荐；相似照片优先推荐最佳瞬间，有独立价值可推荐多张。偏暗但可修复的标记候选或推荐。明显失焦或严重抖动不能直接推荐，注明缺陷。技术质量依据预览可见信息判断。
五项为 composition 构图与视觉平衡、light 光线与色彩、moment 主体与瞬间、technical 技术质量、impact 独特性与感染力。
仅输出 JSON 对象，items 数组包含每个编号一次。例：
{"items":[{"n":1,"scores":{"composition":8.5,"light":8,"moment":9,"technical":8,"impact":8},"decision":"pick","reason":"笑容自然，手势完整，同组背景最干净","technical_issue":false}]}
decision 必须是 pick、maybe 或 skip。reason 用中文给出具体、简短的组内理由。"""


def score_batch(photos, key):
    picture = contact_sheet(photos)
    for attempt in range(3):
        try:
            result = request_vision(key, PROMPT, picture)
            items = result["items"]
            mapped = {}
            for item in items:
                number = int(item["n"])
                scores = {name: float(item["scores"][name]) for name in WEIGHTS}
                if not all(math.isfinite(value) and 0 <= value <= 10 for value in scores.values()):
                    raise ValueError("score out of range")
                decision = item["decision"]
                issue = item["technical_issue"]
                reason = item["reason"]
                if (number in mapped or decision not in {"pick", "maybe", "skip"}
                        or not isinstance(issue, bool) or not isinstance(reason, str) or not reason.strip()):
                    raise ValueError("invalid result")
                total = round(sum(scores[name] * weight / 10 for name, weight in WEIGHTS.items()), 2)
                mapped[number] = {"scores": scores, "total": total,
                                  "decision": "maybe" if issue and decision == "pick" else decision,
                                  "reason": reason, "technical_issue": issue}
            if set(mapped) != set(range(1, len(photos) + 1)):
                raise ValueError("missing or extra photo numbers")
            return {photo["id"]: mapped[n] for n, photo in enumerate(photos, 1)}
        except ContentFiltered:
            raise
        except (OSError, ValueError, TypeError, KeyError) as exc:
            if isinstance(exc, urllib.error.HTTPError) and exc.code in {401, 403, 404}:
                raise
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)


def scoring_batches(project):
    for group in project["groups"]:
        photos = group["photos"]
        for start in range(0, len(photos), 6):
            batch = photos[start:start + 6]
            cache_id = hashlib.sha256((REVISION + MODEL + "".join(photo["id"] for photo in batch)).encode()).hexdigest()
            yield group["id"], cache_id, batch


def score(project, key, data=DATA, progress=None):
    cache_path = data / "scores.json"
    cache = load_json(cache_path, {})
    blocked_path = data / "filtered.json"
    blocked = load_json(blocked_path, {})
    batches = list(scoring_batches(project))
    jobs = [(group_id, cache_id, batch) for group_id, cache_id, batch in batches
            if cache_id not in cache and cache_id not in blocked]
    if progress:
        progress("scoring", len(batches) - len(jobs), len(batches))
    print(f"hy4: {len(jobs)} batches to score", flush=True)
    failures = 0
    with ThreadPoolExecutor(max_workers=4) as executor:
        futures = {executor.submit(score_batch, batch, key): (group_id, cache_id)
                   for group_id, cache_id, batch in jobs}
        for completed, future in enumerate(as_completed(futures), 1):
            group_id, cache_id = futures[future]
            try:
                cache[cache_id] = future.result()
                write_json(cache_path, cache)
                print(f"hy4 group {group_id} complete", flush=True)
            except ContentFiltered:
                blocked[cache_id] = True
                write_json(blocked_path, blocked)
                print(f"hy4 group {group_id} filtered", flush=True)
            except (OSError, ValueError, TypeError, KeyError) as exc:
                failures += 1
                print(f"hy4 group {group_id} failed: {exc}", flush=True)
            if progress:
                progress("scoring", len(batches) - len(jobs) + completed, len(batches))
    return failures


def adjust(source):
    photo = ImageOps.exif_transpose(source).convert("RGB")
    sample = photo.copy()
    sample.thumbnail((640, 640))
    median = ImageStat.Stat(sample.convert("L")).median[0]
    exposure = max(0.92, min(1.16, 1 + (118 - median) / 520))
    # A curved lift leaves highlights close to their original level.
    if exposure > 1:
        curve = [round(i + (exposure - 1) * i * (1 - i / 255)) for i in range(256)]
        photo = photo.point(curve * 3)
    else:
        photo = ImageEnhance.Brightness(photo).enhance(exposure)
    return ImageEnhance.Color(ImageEnhance.Contrast(photo).enhance(1.035)).enhance(1.035)


def export_photo(photo, mode, destination, relative=None):
    source = Path(photo["file"])
    target = destination / (relative or photo["name"])
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        raise FileExistsError(f"导出目录已有同名文件：{photo['name']}")
    try:
        if mode == "original":
            with target.open("xb") as output, source.open("rb") as original:
                shutil.copyfileobj(original, output)
        else:
            with Image.open(source) as original, target.open("xb") as output:
                adjusted = adjust(original)
                adjusted.save(output, format="JPEG", quality=94, icc_profile=original.info.get("icc_profile"))
    except (OSError, ValueError):
        # The export directory is unique to this request.
        target.unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["scan", "score", "serve"])
    parser.add_argument("--source", type=Path, default=ROOT.parent / "越野跑")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    if args.action == "scan":
        if not args.source.is_dir():
            parser.error("Source directory does not exist")
        scan(args.source.resolve())
    elif args.action == "score":
        key = os.environ.get("TOKENLINK_API_KEY")
        if not key:
            import getpass
            key = getpass.getpass("TokenLink API key: ")
        project = load_json(DATA / "project.json", None)
        if not key.strip() or project is None:
            parser.error("Scan the source folder first and provide a TokenLink API key")
        raise SystemExit(bool(score(project, key.strip())))
    else:
        from review import serve
        serve(args.port)


if __name__ == "__main__":
    main()

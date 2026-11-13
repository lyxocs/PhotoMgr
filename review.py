import json
import os
import re
import secrets
import socket
from datetime import datetime
from collections import Counter
from functools import lru_cache
from io import BytesIO
from threading import Lock

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from photo_review import (
    CAPTURE_VERSION, PREVIEWS, ROOT, WEIGHTS, apply_portrait_review, capture_time, export_photo,
    load_json, regional_grade, request_vision, review_group_mapping, scoring_batches, write_json,
)

from PIL import Image
from batches import LEGACY, batch_data, batch_status, folder_contents, enqueue, list_batches

TOKEN = secrets.token_urlsafe(24)
REVIEW_LOCK = Lock()


@lru_cache(maxsize=8192)
def read_capture_time(path, modified, size):
    with Image.open(path) as original:
        return capture_time(original)


def project_state(batch_id=LEGACY):
    data = batch_data(batch_id)
    project = load_json(data / "project.json", {"groups": [], "input_count": 0, "errors": []})
    scoring_data = data / "rescore"
    published = load_json(scoring_data / "published.json", None)
    scoring_project = published or project
    if published is None:
        scoring_data = data
    batches = load_json(scoring_data / "scores.json", {})
    scores = {photo_id: rating for _, cache_id, _ in scoring_batches(scoring_project)
              for photo_id, rating in batches.get(cache_id, {}).items()}
    filtered = load_json(scoring_data / "filtered.json", {})
    filtered_ids = {photo["id"] for _, cache_id, photos in scoring_batches(scoring_project)
                    if cache_id in filtered for photo in photos}
    review = load_json(data / "review.json", {})
    blur_flags = load_json(data / "blur.json", {})
    portrait_reviews = load_json(data / "portrait-review.json", {})
    for group in project["groups"]:
        for photo in group["photos"]:
            if not photo.get("captured") and photo.get("capture_version") != CAPTURE_VERSION:
                try:
                    info = Path(photo["file"]).stat()
                    photo["captured"] = read_capture_time(photo["file"], info.st_mtime_ns, info.st_size)
                except (OSError, ValueError):
                    photo["captured"] = None
            rating = scores.get(photo["id"])
            if rating:
                rating = dict(rating)
                if correction := portrait_reviews.get(photo["id"]):
                    rating = apply_portrait_review(
                        rating,
                        correction.get("expression", rating.get("expression")),
                        correction.get("face_overexposed", rating.get("face_overexposed", False)),
                        manual=True,
                    )
                # Combine the model's relative judgment with the absolute weighted score.
                if rating["decision"] == "pick" and rating["total"] < 70:
                    rating["decision"] = "maybe"
            photo["rating"] = rating
            photo["filtered"] = not rating and photo["id"] in filtered_ids
            photo["blurred"] = bool(blur_flags.get(photo["id"]))
            recommended = bool(rating and rating["decision"] == "pick" and not rating.get("technical_issue"))
            photo["selected"] = not photo["blurred"] and review.get(photo["id"], recommended)
            photo.pop("file")
            photo["duplicates"] = [duplicate["name"] for duplicate in photo["duplicates"]]
        group["photos"].sort(key=lambda photo: -(photo["rating"]["total"] if photo["rating"] else -1))
    project["batch"] = batch_id
    project["review_group_ids"] = review_group_mapping(project["groups"], data)
    project["progress"] = batch_status(batch_id, data)
    project["weights"] = WEIGHTS
    project["token"] = TOKEN
    project["grade_advice"] = list(load_json(data / "grade-advice.json", {}))
    return project


class ReviewHandler(BaseHTTPRequestHandler):
    def respond(self, code, body, content_type):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionAbortedError, ConnectionResetError):
            pass

    def json_response(self, code, value):
        self.respond(code, json.dumps(value, ensure_ascii=False).encode(), "application/json; charset=utf-8")

    def batch_id(self):
        return parse_qs(urlsplit(self.path).query).get("batch", [LEGACY])[0]

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/":
            self.respond(200, (ROOT / "review.html").read_bytes(), "text/html; charset=utf-8")
        elif path == "/api/batches":
            self.json_response(200, {"batches": list_batches(), "token": TOKEN})
        elif path == "/api/project":
            try:
                self.json_response(200, project_state(self.batch_id()))
            except (ValueError, OSError) as exc:
                self.json_response(400, {"error": str(exc)})
        elif re.fullmatch(r"/preview/[a-f0-9]{64}\.jpg", path):
            photo = PREVIEWS / Path(path).name
            if photo.is_file():
                self.photo_preview(photo)
            else:
                self.send_error(404)
        else:
            self.send_error(404)

    def photo_preview(self, preview):
        query = parse_qs(urlsplit(self.path).query)
        default_view = "adjusted" if query.get("adjusted") == ["1"] else "original"
        view = query.get("view", [default_view])[0]
        full_size = query.get("full") == ["1"]
        if view == "original" and not full_size:
            self.respond(200, preview.read_bytes(), "image/jpeg")
            return
        try:
            data = batch_data(self.batch_id())
            source = preview
            if full_size:
                project = load_json(data / "project.json", {"groups": []})
                match = next((photo for group in project["groups"] for photo in group["photos"]
                              if photo["id"] == preview.stem), None)
                if match is None:
                    self.send_error(404)
                    return
                source = Path(match["file"])
            if view == "original":
                self.respond(200, source.read_bytes(), "image/jpeg")
                return
            advice = load_json(data / "grade-advice.json", {}).get(preview.stem) if view == "adjusted" else None
            with Image.open(source) as original:
                buffer = BytesIO()
                graded, _ = regional_grade(original, preview, advice, overlay=view == "masks")
                graded.save(buffer, format="JPEG", quality=92, icc_profile=original.info.get("icc_profile"))
            self.respond(200, buffer.getvalue(), "image/jpeg")
        except (ImportError, OSError, ValueError, RuntimeError) as exc:
            self.json_response(503, {"error": f"预览不可用：{exc}"})

    def do_POST(self):
        if self.headers.get("X-Review-Token") != TOKEN:
            self.json_response(403, {"error": "请刷新页面后重试"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 8000000:
                raise ValueError("请求大小不正确")
            payload = json.loads(self.rfile.read(length))
            path = urlsplit(self.path).path
            if path == "/api/folder":
                self.json_response(200, folder_contents(payload.get("path")))
                return
            if path == "/api/batches":
                self.json_response(202, {"batch": enqueue(payload)})
                return
            batch_id = self.batch_id()
            data = batch_data(batch_id)
            project = load_json(data / "project.json", {"groups": []})
            photos = {photo["id"]: photo for group in project["groups"] for photo in group["photos"]}
            if path == "/api/grade-advice":
                from local_grade import PROMPT, validate_advice

                photo_id = payload["photo"]
                if photo_id not in photos:
                    raise ValueError("照片不在当前批次")
                advice_path = data / "grade-advice.json"
                reset = payload.get("reset") is True
                if not reset:
                    key = payload.get("key") or os.environ.get("TOKENLINK_API_KEY", "")
                    if not isinstance(key, str) or not key.strip():
                        raise ValueError("请填写 TokenLink API Key")
                    picture = (PREVIEWS / f"{photo_id}.jpg").read_bytes()
                    advice = validate_advice(request_vision(key.strip(), PROMPT, picture, max_tokens=512))
                with REVIEW_LOCK:
                    saved = load_json(advice_path, {})
                    if reset:
                        saved.pop(photo_id, None)
                    else:
                        saved[photo_id] = advice
                    write_json(advice_path, saved)
                self.json_response(200, {"enabled": not reset})
                return
            if path == "/api/blur":
                photo_id = payload["photo"]
                blurred = payload["blurred"]
                if photo_id not in photos or type(blurred) is not bool:
                    raise ValueError("模糊标记无效")
                with REVIEW_LOCK:
                    flags = load_json(data / "blur.json", {})
                    if blurred:
                        flags[photo_id] = True
                    else:
                        flags.pop(photo_id, None)
                    write_json(data / "blur.json", flags)
                self.json_response(200, {"blurred": blurred})
                return
            choices = payload["choices"]
            if not isinstance(choices, dict) or any(key not in photos or type(value) is not bool
                                                   for key, value in choices.items()):
                raise ValueError("勾选结果无效")
            if path == "/api/review":
                with REVIEW_LOCK:
                    saved = load_json(data / "review.json", {})
                    saved.update(choices)
                    write_json(data / "review.json", saved)
                self.json_response(200, {"saved": len(choices)})
            elif path == "/api/export":
                mode = payload["mode"]
                if mode not in {"original", "adjusted"}:
                    raise ValueError("导出类型无效")
                blur_flags = load_json(data / "blur.json", {})
                selected = [photos[key] for key, value in choices.items() if value and not blur_flags.get(key)]
                if not selected:
                    raise ValueError("请至少勾选一张照片")
                stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
                destination = ROOT / "exports" / f"{stamp}-{mode}"
                if batch_id != LEGACY:
                    destination = destination.parent / batch_id / destination.name
                destination.mkdir(parents=True)
                names = Counter(photo["name"].casefold() for photo in selected)
                source = Path(project["source"])
                grade_advice = load_json(data / "grade-advice.json", {}) if mode == "adjusted" else {}
                failures = []
                for photo in selected:
                    try:
                        relative = Path(photo["file"]).relative_to(source) if names[photo["name"].casefold()] > 1 else None
                        export_photo(photo, mode, destination, relative, grade_advice.get(photo["id"]))
                    except (ImportError, OSError, ValueError, RuntimeError) as exc:
                        failures.append(f"{photo['name']}：{exc}")
                self.json_response(200, {"count": len(selected) - len(failures), "folder": str(destination),
                                         "failures": failures})
            else:
                self.send_error(404)
        except (ImportError, KeyError, OSError, ValueError, TypeError, RuntimeError) as exc:
            self.json_response(400, {"error": str(exc)})


class ReviewServer(ThreadingHTTPServer):
    def server_bind(self):
        if os.name == "nt":
            self.allow_reuse_address = False
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()


def serve(port):
    with ReviewServer(("127.0.0.1", port), ReviewHandler) as server:
        print(f"Photo review at http://127.0.0.1:{port}/", flush=True)
        server.serve_forever()

import json
import re
import secrets
from datetime import datetime
from collections import Counter
from io import BytesIO
from threading import Lock

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from photo_review import DATA, PREVIEWS, ROOT, WEIGHTS, adjust, export_photo, load_json, scoring_batches, write_json

from PIL import Image
from batches import LEGACY, batch_data, batch_status, folder_contents, enqueue, list_batches

TOKEN = secrets.token_urlsafe(24)
REVIEW_LOCK = Lock()


def project_state(batch_id=LEGACY):
    data = batch_data(batch_id)
    project = load_json(data / "project.json", {"groups": [], "input_count": 0, "errors": []})
    batches = load_json(data / "scores.json", {})
    scores = {photo_id: rating for _, cache_id, _ in scoring_batches(project)
              for photo_id, rating in batches.get(cache_id, {}).items()}
    filtered = load_json(data / "filtered.json", {})
    filtered_ids = {photo["id"] for _, cache_id, photos in scoring_batches(project)
                    if cache_id in filtered for photo in photos}
    review = load_json(data / "review.json", {})
    for group in project["groups"]:
        for photo in group["photos"]:
            rating = scores.get(photo["id"])
            if rating:
                rating = dict(rating)
                # Combine the model's relative judgment with the absolute weighted score.
                if rating["decision"] == "pick" and rating["total"] < 70:
                    rating["decision"] = "maybe"
            photo["rating"] = rating
            photo["filtered"] = not rating and photo["id"] in filtered_ids
            photo["selected"] = review.get(photo["id"], bool(rating and rating["decision"] == "pick"))
            photo.pop("file")
            photo["duplicates"] = [duplicate["name"] for duplicate in photo["duplicates"]]
        group["photos"].sort(key=lambda photo: -(photo["rating"]["total"] if photo["rating"] else -1))
    project["batch"] = batch_id
    project["progress"] = batch_status(batch_id, data)
    project["weights"] = WEIGHTS
    project["token"] = TOKEN
    return project


class ReviewHandler(BaseHTTPRequestHandler):
    def respond(self, code, body, content_type):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

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
                if urlsplit(self.path).query == "adjusted=1":
                    with Image.open(photo) as original:
                        buffer = BytesIO()
                        adjust(original).save(buffer, format="JPEG", quality=88,
                                              icc_profile=original.info.get("icc_profile"))
                    self.respond(200, buffer.getvalue(), "image/jpeg")
                else:
                    self.respond(200, photo.read_bytes(), "image/jpeg")
            else:
                self.send_error(404)
        else:
            self.send_error(404)

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
                selected = [photos[key] for key, value in choices.items() if value]
                if not selected:
                    raise ValueError("请至少勾选一张照片")
                stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
                destination = ROOT / "exports" / f"{stamp}-{mode}"
                if batch_id != LEGACY:
                    destination = destination.parent / batch_id / destination.name
                destination.mkdir(parents=True)
                names = Counter(photo["name"].casefold() for photo in selected)
                source = Path(project["source"])
                failures = []
                for photo in selected:
                    try:
                        relative = Path(photo["file"]).relative_to(source) if names[photo["name"].casefold()] > 1 else None
                        export_photo(photo, mode, destination, relative)
                    except (OSError, ValueError) as exc:
                        failures.append(f"{photo['name']}：{exc}")
                self.json_response(200, {"count": len(selected) - len(failures), "folder": str(destination),
                                         "failures": failures})
            else:
                self.send_error(404)
        except (KeyError, OSError, ValueError, TypeError) as exc:
            self.json_response(400, {"error": str(exc)})


def serve(port):
    with ThreadingHTTPServer(("127.0.0.1", port), ReviewHandler) as server:
        print(f"Photo review at http://127.0.0.1:{port}/", flush=True)
        server.serve_forever()

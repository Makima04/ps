#!/usr/bin/env python3
"""Local-only bridge: receive observed browser image URLs and archive their bytes.

No cookies, private APIs or request signing. Only public xhscdn image URLs from
the rendered post are accepted. Browser navigation sends each small manifest to
a random local endpoint; bounded download workers do the file work directly.
"""
import base64
import hashlib
import importlib.util
import io
import json
import queue
import secrets
import threading
import time
import uuid
import urllib.parse
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from zoneinfo import ZoneInfo

from PIL import Image, ImageOps

spec=importlib.util.spec_from_file_location("library",Path(__file__).with_name("reference-library.py"))
library=importlib.util.module_from_spec(spec)
spec.loader.exec_module(library)
ROOT=library.ROOT
ROOT.mkdir(parents=True,exist_ok=True)
TOKEN=secrets.token_urlsafe(18)
DOWNLOADS=queue.Queue()
ANALYSIS=queue.Queue()
LOCK=threading.Lock()
COUNTS={"accepted":0,"archived":0,"analyzed":0,"failed":0}
CATALOG={}
SEEN=set()
STATE=ROOT/"采集清单.json"
if STATE.exists():
    previous=json.loads(STATE.read_text())
    CATALOG={n["id"]:n for n in previous.get("notes",[])}


def checkpoint(complete=False):
    library.dump(STATE,{"author":"光月大青蛙","author_id":"5af2ad89f7e8b942e5fbaebd",
        "captured_on":datetime.now(ZoneInfo("Asia/Shanghai")).date().isoformat(),
        "profile_end_observed":complete,"notes":list(CATALOG.values()),"progress":dict(COUNTS)})


def validate_id(ident):
    import re
    if not re.fullmatch(r"[a-f0-9]{24}",ident):raise ValueError("Invalid post ID")


def fetch_once(row):
    parsed=urllib.parse.urlsplit(row["url"])
    if parsed.scheme!="https" or not parsed.hostname or not parsed.hostname.endswith(".xhscdn.com"):
        raise ValueError("Only observed xhscdn image URLs are accepted")
    request=urllib.request.Request(row["url"],headers={"User-Agent":"Mozilla/5.0","Referer":"https://www.xiaohongshu.com/"})
    with urllib.request.urlopen(request,timeout=30) as response:
        data=response.read(30*1024*1024+1)
    if len(data)>30*1024*1024:raise ValueError("Image too large")
    with Image.open(io.BytesIO(data)) as image:
        image.load()
        extension={"WEBP":"webp","JPEG":"jpg","PNG":"png"}.get(image.format)
        if not extension:raise ValueError("Unsupported image encoding")
        size=list(ImageOps.exif_transpose(image).size)
        profile="embedded ICC" if image.info.get("icc_profile") else "untagged; assumed sRGB for analysis"
    return data,extension,size,profile


def fetch_image(row):
    for attempt in range(4):
        try:return fetch_once(row)
        except urllib.error.HTTPError as error:
            if error.code<500 or attempt==3:raise
        except (urllib.error.URLError,TimeoutError,ConnectionError):
            if attempt==3:raise
        time.sleep(0.5*(2**attempt))


def archive(post):
    post["captured_on"]=datetime.now(ZoneInfo("Asia/Shanghai")).date().isoformat()
    folder=ROOT/library.folder_name(post)
    metadata=folder/"post.json"
    if metadata.exists():
        old=json.loads(metadata.read_text())
        if old["id"]==post["id"] and old["count"]==len(post["images"]):
            # Older browser downloads included Swiper's cloned last slide first.
            # Match immutable asset IDs to the observed slide indexes, then move
            # filenames and their analysis masks together without re-encoding.
            def asset(row):
                value=row.get("source_url",row.get("source_filename",""))
                return urllib.parse.urlsplit(value).path.rsplit("/",1)[-1].split("!")[0]
            by_asset={asset(row):row for row in old["images"]}
            order=[urllib.parse.urlsplit(row["url"]).path.rsplit("/",1)[-1].split("!")[0] for row in post["images"]]
            if len(set(order))!=len(order) or set(order)!=set(by_asset):
                raise ValueError("Existing asset membership differs; refusing reorder")
            ordered=[dict(by_asset[key]) for key in order]
            mapping={}
            moves=[]
            for index,(row,source_row) in enumerate(zip(ordered,post["images"]),1):
                before=Path(row["file"]);after=Path(f"{index:03d}{before.suffix}")
                mapping[str(before)]=str(after)
                if before!=after:
                    source=folder/before;temporary=folder/(".order-"+uuid.uuid4().hex+before.suffix)
                    source.rename(temporary);moves.append((temporary,folder/after))
                    masks=folder/"分析/蒙版"/before.stem
                    if masks.exists():
                        temporary=masks.parent/(".order-"+uuid.uuid4().hex)
                        masks.rename(temporary);moves.append((temporary,masks.parent/after.stem))
                row["file"]=str(after);row["source_url"]=source_row["url"]
            for temporary,destination in moves:temporary.rename(destination)
            old.update({"images":ordered,"order_verified":"Rendered swiper slide indexes","tags":post.get("tags",[])})
            library.dump(metadata,old)
            features=folder/"分析/特征.json"
            if features.exists():
                report=json.loads(features.read_text())
                for row in report.get("images",[]):row["file"]=mapping.get(row["file"],row["file"])
                report["images"].sort(key=lambda row:row["file"])
                library.dump(features,report)
            library.contact_sheet(folder,old)
            return folder
        raise ValueError("Existing post differs; refusing overwrite")
    folder.mkdir(parents=True,exist_ok=True)
    saved=[]
    with ThreadPoolExecutor(max_workers=3) as pool:
        results=pool.map(fetch_image,post["images"])
        for index,(row,result) in enumerate(zip(post["images"],results),1):
            data,extension,size,profile=result
            destination=folder/f"{index:03d}.{extension}"
            digest=hashlib.sha256(data).hexdigest()
            if destination.exists():
                if hashlib.sha256(destination.read_bytes()).hexdigest()!=digest:
                    raise ValueError("Existing image differs; refusing overwrite")
            else:
                temporary=destination.with_suffix(destination.suffix+".part")
                temporary.write_bytes(data);temporary.replace(destination)
            saved.append({"file":destination.name,"source_url":row["url"],"sha256":digest,"size":size,"profile":profile})
    library.dump(metadata,{**post,"author":"光月大青蛙","count":len(saved),"images":saved,
        "source_quality":"Website-served images; downloaded bytes preserved; not camera originals"})
    return folder


def download_worker():
    while True:
        post=DOWNLOADS.get()
        if post is None:DOWNLOADS.task_done();return
        try:
            folder=archive(post)
            with LOCK:COUNTS["archived"]+=1;checkpoint()
            ANALYSIS.put(folder)
            print(f"归档 {post['id']} {len(post['images'])} 张",flush=True)
        except Exception as error:
            with LOCK:COUNTS["failed"]+=1;checkpoint()
            library.dump(ROOT/"采集错误"/(post["id"]+".json"),{"post":post,"error":str(error)})
            print(f"失败 {post['id']}: {error}",flush=True)
        finally:DOWNLOADS.task_done()


def analysis_worker():
    while True:
        folder=ANALYSIS.get()
        if folder is None:ANALYSIS.task_done();return
        try:
            library.analyze(folder)
            with LOCK:COUNTS["analyzed"]+=1;checkpoint()
        except Exception as error:
            library.dump(folder/"分析/分析失败.json",{"error":str(error)})
            print(f"分析失败 {folder.name}: {error}",flush=True)
        finally:ANALYSIS.task_done()


class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        parts=urllib.parse.urlsplit(self.path)
        if parts.path!="/capture/"+TOKEN:
            self.send_error(404);return
        try:
            payload=urllib.parse.parse_qs(parts.query).get("data",[""])[0]
            data=json.loads(base64.urlsafe_b64decode(payload+"="*((-len(payload))%4)))
            if data["kind"]=="catalog":
                with LOCK:
                    for note in data["notes"]:
                        validate_id(note["id"]);CATALOG[note["id"]]=note
                    checkpoint()
            elif data["kind"]=="post":
                post=data["post"];validate_id(post["id"])
                if post["id"] not in SEEN:
                    SEEN.add(post["id"]);COUNTS["accepted"]+=1
                    DOWNLOADS.put(post)
            elif data["kind"]=="finish":
                def finish():
                    DOWNLOADS.join();ANALYSIS.join()
                    with LOCK:checkpoint(complete=bool(data.get("profile_end_observed")))
                    print("队列处理完毕 "+json.dumps(COUNTS,ensure_ascii=False),flush=True)
                    self.server.shutdown()
                threading.Thread(target=finish,daemon=True).start()
            elif data["kind"]!="status":raise ValueError("Unknown request")
            response=json.dumps({"ok":True,"catalog":len(CATALOG),**COUNTS},ensure_ascii=False).encode()
            self.send_response(200);self.send_header("Content-Type","application/json; charset=utf-8")
            self.send_header("Content-Length",str(len(response)));self.end_headers();self.wfile.write(response)
        except Exception as error:self.send_error(400,str(error))


if __name__=="__main__":
    server=ThreadingHTTPServer(("127.0.0.1",0),Handler)
    for _ in range(2):threading.Thread(target=download_worker,daemon=True).start()
    threading.Thread(target=analysis_worker,daemon=True).start()
    endpoint=f"http://127.0.0.1:{server.server_port}/capture/{TOKEN}"
    endpoint_file=Path(__file__).resolve().parent.parent/".build/QA/xhs-capture-endpoint.txt"
    endpoint_file.parent.mkdir(parents=True,exist_ok=True)
    endpoint_file.write_text(endpoint)
    print(endpoint,flush=True)
    server.serve_forever(poll_interval=0.2)

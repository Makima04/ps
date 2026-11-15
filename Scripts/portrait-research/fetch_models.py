#!/usr/bin/env python3
"""Download only official research checkpoints and verify publisher SHA-256."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
from pathlib import Path
import subprocess
import time
import urllib.parse
import urllib.request


def read_json(url):
    with urllib.request.urlopen(url, timeout=45) as response:
        return json.load(response)


def sha256(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def download(entry, root):
    target = root / 'models' / entry['name']
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and sha256(target) == entry['sha256']:
        return {**entry, 'path': str(target.resolve()), 'verified': True, 'cached': True}
    temporary = target.with_suffix(target.suffix + '.partial')
    started = time.monotonic()
    for attempt in range(3):
        try:
            print('下载', entry['name'], round(entry['bytes']/1024**2), 'MiB', flush=True)
            request = urllib.request.Request(entry['url'], headers={'User-Agent': 'PsPortraitResearch/1.0'})
            with urllib.request.urlopen(request, timeout=90) as response, temporary.open('wb') as stream:
                while block := response.read(4 * 1024 * 1024):
                    stream.write(block)
            if temporary.stat().st_size != entry['bytes'] or sha256(temporary) != entry['sha256']:
                raise ValueError('文件尺寸或 SHA-256 与发布者信息不一致')
            temporary.replace(target)
            print('已校验', entry['name'], round(time.monotonic()-started, 1), '秒', flush=True)
            return {**entry, 'path': str(target.resolve()), 'verified': True,
                    'download_seconds': round(time.monotonic()-started, 3)}
        except Exception as error:
            print('下载失败', entry['name'], repr(error), flush=True)
            if attempt == 2:
                return {**entry, 'verified': False, 'error': repr(error)}
    raise AssertionError('unreachable')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    specifications = [
        ('kartiknarayan/SegFace', 'mobilenet_celeba_512/model_299.pt', 'segface-mobile.pt'),
        ('kartiknarayan/SegFace', 'swinb_celeba_512/model_299.pt', 'segface-swin.pt'),
        ('facebook/sapiens2-seg-0.4b', 'model.safetensors', 'sapiens2-seg-0.4b.safetensors'),
    ]
    entries = []
    for repository, file, name in specifications:
        metadata = read_json('https://huggingface.co/api/models/' + repository)
        revision = metadata['sha']
        files = read_json(f'https://huggingface.co/api/models/{repository}/tree/{revision}?recursive=true')
        record = next(f for f in files if f['path'] == file)
        entries.append(dict(name=name, repository=repository, revision=revision, file=file,
            url=f'https://huggingface.co/{repository}/resolve/{revision}/{file}?download=true',
            sha256=record['lfs']['oid'], bytes=record['size']))
    repository = 'iic/cv_unet_skin_retouching_torch'
    metadata = read_json(f'https://modelscope.cn/api/v1/models/{repository}/repo/files?Revision=master&Recursive=true')
    revision = metadata['Data']['LatestCommitter']['Id']
    for name in ['joint_20210926.pth', 'pytorch_model.pt']:
        record = next(f for f in metadata['Data']['Files'] if f['Path'] == name)
        entries.append(dict(name='modelscope-' + name, repository=repository, revision=revision,
            file=name, url=f'https://modelscope.cn/models/{repository}/resolve/master/{name}',
            sha256=record['Sha256'], bytes=record['Size']))
    manifest = dict(models=entries, sources={})
    for repo in sorted((root / 'repos').iterdir()):
        if (repo / '.git').is_dir():
            manifest['sources'][repo.name] = subprocess.check_output(
                ['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
    manifest_path = root / 'model-manifest.json'
    manifest_path.write_text(json.dumps(manifest, indent=2))
    results = []
    with ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(download, entry, root) for entry in entries]
        for future in as_completed(futures):
            results.append(future.result())
            manifest['models'] = results + [e for e in entries if e['name'] not in {r['name'] for r in results}]
            manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
    if any(not entry.get('verified') for entry in results):
        raise SystemExit(1)


if __name__ == '__main__':
    main()

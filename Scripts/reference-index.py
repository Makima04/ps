#!/usr/bin/env python3
"""Build a local, searchable index and a compact per-post colour feature table."""
import csv
import html
import json
from pathlib import Path
from urllib.parse import quote

ROOT=Path(__file__).resolve().parent.parent/"博主参考图库/光月大青蛙"


def build():
    rows=[]
    for source in ROOT.glob("*/post.json"):
        post=json.loads(source.read_text())
        folder=source.parent
        report=folder/"分析/特征.json"
        features=json.loads(report.read_text()) if report.exists() else {}
        summary=features.get("summary",{})
        def value(region,channel):return summary.get(region,{}).get(channel,{}).get("median")
        row={"id":post["id"],"title":post["title"],"date":post.get("date_text",""),
             "count":post["count"],"kind":post["kind"],"url":post["url"],"folder":folder.name,
             "analyzed":features.get("status")=="complete","face_L":value("face_skin","L"),
             "face_a":value("face_skin","a"),"face_b":value("face_skin","b"),"face_C":value("face_skin","C"),
             "background_L":value("background","L"),"background_C":value("background","C"),
             "clothing_L":value("clothing","L"),"clothing_C":value("clothing","C"),
             "face_valid_images":summary.get("face_skin",{}).get("valid_images",0),
             "tags":post.get("tags",[])}
        row["cover"]=f"{quote(folder.name)}/{quote(post['images'][0]['file'])}" if post["images"] else ""
        palettes=[]
        for item in features.get("images",[]):
            palette=item.get("regions",{}).get("background",{}).get("palette",[])
            if palette:palettes=palette;break
        row["palette"]=[p["hex"] for p in palettes]
        rows.append(row)
    rows.sort(key=lambda row:row["id"],reverse=True)
    ROOT.mkdir(parents=True,exist_ok=True)
    (ROOT/"帖子特征汇总.json").write_text(json.dumps(rows,ensure_ascii=False,indent=2),encoding="utf-8")
    fields=["id","title","date","count","kind","analyzed","face_L","face_a","face_b","face_C",
            "face_valid_images","background_L","background_C","clothing_L","clothing_C","folder","url"]
    with (ROOT/"帖子特征汇总.csv").open("w",encoding="utf-8-sig",newline="") as stream:
        writer=csv.DictWriter(stream,fieldnames=fields,extrasaction="ignore");writer.writeheader()
        writer.writerows({key:("'"+value if isinstance(value,str) and value.startswith(("=","+","-","@","\t","\r")) else value)
                         for key,value in row.items()} for row in rows)
    photo_posts=sum(row["kind"]=="image" for row in rows)
    videos=sum(row["kind"]=="video" for row in rows)
    total=sum(row["count"] for row in rows)
    ready=sum(row["analyzed"] for row in rows)
    data=json.dumps(rows,ensure_ascii=False).replace("<","\\u003c").replace(">","\\u003e").replace("&","\\u0026")
    document="""<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>光月大青蛙 · 帖子参考图库</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#121519;color:#f2f2f2;font:15px -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif}
header{padding:32px max(24px,5vw);background:#1b2027;border-bottom:1px solid #39414b}h1{margin:0 0 12px;font-size:27px}
p{line-height:1.7;color:#b9c2cb;margin:8px 0}a{color:#afcfef;text-decoration:none}a:hover{text-decoration:underline}
.controls{display:flex;gap:12px;flex-wrap:wrap;margin-top:22px}input,select{background:#11161c;color:#eee;border:1px solid #59626e;border-radius:8px;padding:11px;font-size:15px}input{width:min(420px,100%)}
main{padding:28px max(24px,5vw)}#grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:22px}.card{background:#1d232b;border:1px solid #333e4a;border-radius:12px;overflow:hidden}
.cover{width:100%;height:320px;object-fit:cover;background:#252e38}.empty{height:180px;display:grid;place-items:center;color:#bdc7d4}.body{padding:17px}h2{margin:0 0 9px;font-size:17px;line-height:1.55;min-height:52px}.meta{font-size:12px;color:#9eacbb}
.stats{display:grid;grid-template-columns:1fr 1fr;gap:8px;background:#131920;padding:12px;margin:14px 0;border-radius:7px;font-size:13px}.stats b{font-weight:600;color:#fff}.swatches{display:flex;gap:5px;margin:10px 0}.swatch{height:18px;width:28px;border:1px solid #ffffff35;border-radius:4px}.links{display:flex;gap:13px;flex-wrap:wrap;font-size:13px}.status{padding:12px 0;color:#bacbdc}#count{margin-bottom:20px;color:#aebdcd}
</style><header><h1>光月大青蛙 · 按帖子归档的参考图库</h1><p>__TOTAL__ 张图片 · __PHOTO__ 篇图文 · __VIDEO__ 篇视频记录 · __READY__ 篇已提取特征</p>
<p>照片保留网页下载文件及分辨率。肤色、服装、背景分别统计；自动蒙版可打开检查。日期来自帖子页面，可能为编辑时间；只标月日时保留月日。</p>
<p><a href="帖子特征汇总.csv">下载汇总 CSV</a>　<a href="帖子特征汇总.json">查看汇总 JSON</a>　<a href="说明.md">目录与统计说明</a></p>
<div class="controls"><input id="search" placeholder="搜索帖子标题、日期或标签" aria-label="搜索帖子"><select id="kind" aria-label="帖子类型"><option value="all">全部帖子</option><option value="image">图文帖</option><option value="video">视频记录</option></select><select id="style" aria-label="参考特征筛选"><option value="all">全部色彩</option><option value="light">肤色 L* ≥ 70</option><option value="muted">背景 C* ＜ 12</option><option value="colorful">背景 C* ≥ 25</option></select></div></header>
<main><div id="count"></div><div id="grid"></div></main><script>
const rows=__DATA__;const grid=document.querySelector('#grid');const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));const num=v=>v==null?'—':v.toFixed(1);
function draw(){const q=document.querySelector('#search').value.toLowerCase(),kind=document.querySelector('#kind').value,style=document.querySelector('#style').value;const chosen=rows.filter(r=>[r.title,r.date,...r.tags].join(' ').toLowerCase().includes(q)&&(kind==='all'||r.kind===kind)&&(style==='all'||style==='light'&&r.face_L!=null&&r.face_L>=70||style==='muted'&&r.background_C!=null&&r.background_C<12||style==='colorful'&&r.background_C!=null&&r.background_C>=25));document.querySelector('#count').textContent=`显示 ${chosen.length} 篇 / 已归档 ${rows.length} 篇`;grid.innerHTML=chosen.map(r=>{const base=encodeURIComponent(r.folder)+'/';return `<article class="card">${r.cover?`<a href="${esc(base)}"><img class="cover" loading="lazy" src="${esc(r.cover)}" alt="${esc(r.title)}"></a>`:'<div class="empty">视频帖 · 仅记录来源</div>'}<div class="body"><h2>${esc(r.title)}</h2><div class="meta">${esc(r.date)} · ${r.count} 张 · ${esc(r.id.slice(-6))}</div>${r.analyzed?`<div class="stats"><span>肤色 L* <b>${num(r.face_L)}</b></span><span>肤色 C* <b>${num(r.face_C)}</b></span><span>背景 L* <b>${num(r.background_L)}</b></span><span>背景 C* <b>${num(r.background_C)}</b></span></div><div class="swatches" title="首张有效图的背景色板">${r.palette.map(c=>`<span class="swatch" style="background:${c}" title="${c}"></span>`).join('')}</div>`:`<div class="status">${r.kind==='video'?'视频未提取静态图特征':'特征提取中或需检查'}</div>`}<div class="links"><a href="${esc(base)}">图片文件夹</a>${r.analyzed?`<a href="${esc(base+'分析/图集总览.jpg')}">图集总览</a><a href="${esc(base+'分析/特征.json')}">特征数据</a><a href="${esc(base+'分析/蒙版/')}">检查蒙版</a>`:''}<a target="_blank" rel="noreferrer" href="${esc(r.url)}">原帖</a></div></div></article>`}).join('')}
for(const id of ['search','kind','style'])document.getElementById(id).addEventListener(id==='search'?'input':'change',draw);draw();
</script></html>"""
    document=document.replace("__TOTAL__",str(total)).replace("__PHOTO__",str(photo_posts)).replace("__VIDEO__",str(videos)).replace("__READY__",str(ready)).replace("__DATA__",data)
    (ROOT/"index.html").write_text(document,encoding="utf-8")
    text=f"""# 博主参考图库：光月大青蛙

当前已归档 {len(rows)} 篇帖子，其中 {photo_posts} 篇图文、{videos} 篇视频记录，共 {total} 张图片；{ready} 篇已提取特征。双击 `index.html` 可搜索、筛选和浏览。

每篇单独一个文件夹，名称为「页面日期－帖子标题－帖子ID末6位」。照片直接存放于该文件夹，按原帖轮播顺序编号 001、002……；`post.json` 保存标题、原帖地址、页面日期、图片尺寸和 SHA-256 校验值。视频帖单独记录来源，不把视频封面冒充整套照片。

`分析/特征.json` 保存每张图的全图、脸部皮肤、服装、背景统计和本帖汇总；`分析/蒙版/` 保存自动选区与着色校验图；`分析/图集总览.jpg` 是派生预览。下载的图片文件保持原始下载字节，不覆盖相机原片，也不对下载图重新压缩。

日期来自页面公开标示的发布或编辑时间，不代表拍摄日期。只显示月日时不猜年份；相对日期按采集当天（中国时区）换算。网页图片已经过平台压缩，未将其标记为相机原始文件。

统计先按嵌入 ICC 转到 sRGB，再计算 CIELAB D65；缺少 ICC 时按 sRGB 解释。L* 为明度，a* 为红绿分量，b* 为黄蓝分量，C* 为彩度。各区域记录分位数、主要色板及像素数量。每篇汇总对各图片等权，避免近景大脸或某张大背景占据更高权重；汇总分位数描述的是各图区域中位数之间的变化。

脸部皮肤统计限定在面积最大的人脸框内，并与皮肤及人物选区相交，排除眼睛、嘴唇、头发，不把手臂、腿部和背景纳入肤色统计。服装与背景使用独立模型选区。自动分割可能有误差，请结合校验图检查；区域过小的图不会纳入该区域的汇总。颜色统计包含光线、妆容、相机显影和平台压缩的影响，不能还原博主原来的修图参数。

`帖子特征汇总.csv` 和 `帖子特征汇总.json` 便于筛选参考；`采集清单.json` 记录发现的帖子及进度，`采集错误/` 保留待补齐记录，已解决记录在其子文件夹中。

本批按用户要求停止在已读取的 200 篇帖子。发现目录中的其余帖子没有继续读取图集，也没有创建空照片文件夹。
"""
    (ROOT/"说明.md").write_text(text,encoding="utf-8")
    print({"posts":len(rows),"images":total,"feature_reports":ready,"index":str(ROOT/"index.html")})


if __name__=="__main__":build()

import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from PIL import Image

PROJECT=Path(__file__).resolve().parent.parent
spec=importlib.util.spec_from_file_location("collector",PROJECT/"Scripts/reference-collector-server.py")
collector=importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class ReferenceLibraryTests(unittest.TestCase):
    def testFolderDateUsesVisibleDateWithoutGuessingYear(self):
        base={"id":"012345678901234567890123","title":"一篇/帖子","captured_on":"2026-11-11"}
        name=collector.library.folder_name({**base,"date_text":"编辑于 10-28 广东"})
        self.assertTrue(name.startswith("10-28－一篇_帖子－"))
        self.assertNotIn("2026",name)
        name=collector.library.folder_name({**base,"date_text":"编辑于 昨天 09:53"})
        self.assertTrue(name.startswith("2026-11-10－"))

    def fixture(self,root):
        post={"id":"012345678901234567890123","title":"轮播顺序","date_text":"2026-11-10",
              "kind":"image","images":[{"order":0,"url":"https://sns-webpic-qc.xhscdn.com/test/a!style"},
                                      {"order":1,"url":"https://sns-webpic-qc.xhscdn.com/test/b!style"}]}
        folder=root/collector.library.folder_name(post)
        folder.mkdir()
        old=[]
        for index,(asset,color) in enumerate([("b","blue"),("a","red")],1):
            file=f"{index:03d}.png"
            Image.new("RGB",(8,12),color).save(folder/file)
            digest=hashlib.sha256((folder/file).read_bytes()).hexdigest()
            old.append({"file":file,"source_filename":asset+"!style.png","sha256":digest})
            masks=folder/"分析/蒙版"/f"{index:03d}"
            masks.mkdir(parents=True)
            (masks/"marker.txt").write_text(asset)
        collector.library.dump(folder/"post.json",{**post,"count":2,"images":old})
        collector.library.dump(folder/"分析/特征.json",{"images":[dict(row) for row in old]})
        return folder,post,old

    def testReorderKeepsImageBytesMasksAndFeaturesTogether(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            folder,post,old=self.fixture(root)
            with patch.object(collector,"ROOT",root),patch.object(collector.library,"contact_sheet"):
                collector.archive(post)
            saved=json.loads((folder/"post.json").read_text())
            for index,before in enumerate([old[1],old[0]],1):
                self.assertEqual(hashlib.sha256((folder/f"{index:03d}.png").read_bytes()).hexdigest(),before["sha256"])
            self.assertEqual((folder/"分析/蒙版/001/marker.txt").read_text(),"a")
            self.assertEqual((folder/"分析/蒙版/002/marker.txt").read_text(),"b")
            report=json.loads((folder/"分析/特征.json").read_text())
            self.assertEqual([row["sha256"] for row in report["images"]],[old[1]["sha256"],old[0]["sha256"]])
            self.assertEqual(saved["images"][0]["file"],"001.png")
            self.assertFalse(list(folder.rglob(".order-*")))

    def testMembershipMismatchDoesNotAlterExistingPhotos(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            folder,post,_=self.fixture(root)
            before={path.name:path.read_bytes() for path in folder.glob("*.png")}
            post["images"][0]["url"]="https://sns-webpic-qc.xhscdn.com/test/c!style"
            with patch.object(collector,"ROOT",root),self.assertRaisesRegex(ValueError,"membership differs"):
                collector.archive(post)
            self.assertEqual(before,{path.name:path.read_bytes() for path in folder.glob("*.png")})


if __name__=="__main__":unittest.main()

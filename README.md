# PhotoMgr

在 Windows 上使用 Python 3.14。首次克隆后，在仓库目录安装依赖。

```powershell
python -m pip install -r requirements.txt
```

双击「打开审核.cmd」启动，或运行 `python photo_review.py serve`，然后打开 http://127.0.0.1:8765/。

- 点照片放大，可切换原图和调色预览。照片下方可展开五项评分。
- 复核默认勾选后点「保存审核」。也可直接导出当前勾选的原始 JPG 或调色 JPG。
- 导出的照片在本项目的 exports 目录。自动调色在本地运行，根据亮度调整影调，并轻微调整对比度和饱和度。导出为全分辨率 JPG。
- 分组结合缩略图的颜色和结构相似度，并参考 EXIF 拍摄时间和文件编号。不同角度、横竖构图或主体移动幅度较大时，可能分成多组。

如需重新扫描或续跑评分，在本目录运行：

    python photo_review.py scan --source "F:\photo\照片文件夹"
    python photo_review.py score

score 使用 TOKENLINK_API_KEY 环境变量，也可在终端隐藏输入密钥。评分向 TokenLink 发送带编号的 JPEG 缩略拼图，成功结果保存在 .data。第一版处理 JPG/JPEG。


## 网页里的批次管理

点「新建批次」，在网页里浏览磁盘和子文件夹，也可以直接粘贴路径。点「开始去重、分组和评分」后，系统会读取该文件夹及其子文件夹的全部 JPG/JPEG，并依次处理排队的批次。TokenLink API Key 可以在网页输入，或由启动服务时的 TOKENLINK_API_KEY 环境变量提供。网页输入的密钥仅用于本次排队任务。

用「照片批次」切换，切换时自动保存手动勾选。服务重启后，可对中断的批次点「续跑当前批次」，已完成的评分会复用。新批次的导出位于 exports 下对应的批次目录。

# PhotoMgr

在 Windows 上安装 Python 3.14 后，双击「打开审核.cmd」。首次启动会自动安装依赖并打开 http://127.0.0.1:8765/。安装和迁移步骤见下文。

- 点照片放大，可切换原图和调色预览。照片下方可展开五项评分。
- 复核默认勾选后点「保存审核」。也可直接导出当前勾选的原始 JPG 或调色 JPG。
- 导出的照片在本项目的 exports 目录。自动调色在本地运行，根据亮度调整影调，并轻微调整对比度和饱和度。导出为全分辨率 JPG。
- 分组结合缩略图的颜色和结构相似度，并参考 EXIF 拍摄时间和文件编号。不同角度、横竖构图或主体移动幅度较大时，可能分成多组。

如需重新扫描或续跑评分，在本目录用启动器创建的虚拟环境运行。

    .\.venv\Scripts\python.exe photo_review.py scan --source "F:\photo\照片文件夹"
    .\.venv\Scripts\python.exe photo_review.py score

score 使用 TOKENLINK_API_KEY 环境变量，也可在终端隐藏输入密钥。评分向 TokenLink 发送带编号的 JPEG 缩略拼图，成功结果保存在 .data。第一版处理 JPG/JPEG。


## 网页里的批次管理

点「新建批次」，在网页里浏览磁盘和子文件夹，也可以直接粘贴路径。点「开始去重、分组和评分」后，系统会读取该文件夹及其子文件夹的全部 JPG/JPEG，并依次处理排队的批次。TokenLink API Key 可以在网页输入，或由启动服务时的 TOKENLINK_API_KEY 环境变量提供。网页输入的密钥仅用于本次排队任务。

用「照片批次」切换，切换时自动保存手动勾选。服务重启后，可对中断的批次点「续跑当前批次」，已完成的评分会复用。新批次的导出位于 exports 下对应的批次目录。

## 换电脑安装

1. 从 GitHub 克隆 PhotoMgr，或在仓库页面选 Code → Download ZIP，再解压到可写的本地文件夹。可以放在任意盘符。
2. 安装 [Python 3.14 for Windows](https://www.python.org/downloads/windows/)。双击「打开审核.cmd」，首次会创建仓库内的 .venv 并自动安装依赖。安装依赖时需要能连接 Python 包源。
3. 在审核页点「新建批次」，从磁盘列表选照片文件夹，输入 TokenLink API Key，再开始处理。评分需要新电脑能访问 TokenLink。也可以在启动脚本前设置 TOKENLINK_API_KEY，网页中留空。已经运行的服务要重启才会读取新的环境变量。

启动失败时查看窗口里的错误和 .data/server-errors.log。默认端口被占用时，在 PowerShell 运行下面的命令改用 8766。

```powershell
.\打开审核.cmd -Port 8766
```

## 带走已有批次

在旧电脑结束正在处理的任务并保存审核。把原照片和项目里的 .data 文件夹复制到新电脑，.data 放在新仓库根目录下。已有成片可以一并复制 exports。虚拟环境 .venv 和旧版依赖目录 .deps 在新电脑上重新安装。

如果照片盘符或目录变了，先双击启动器完成依赖安装，并确保该批次没有运行中的任务。然后从仓库目录运行下面的命令。先列出批次，然后把每个需要迁移的批次 ID 和新照片目录填进去。旧版单批次的 ID 为 legacy。照片在新目录中的相对位置需要保持一致。

```powershell
.\.venv\Scripts\python.exe photo_review.py list-batches
.\.venv\Scripts\python.exe photo_review.py relocate --batch legacy --source "D:\照片\越野跑"
```

完成迁移后刷新审核网页。

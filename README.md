# 手机版订单工具 - GitHub Actions 免费方案

## 原理
- 工具放在你的 GitHub 私有仓库里，由 GitHub 的免费服务器定时/手动运行
- 运行时会自动登录平台、创建订单、监控（待审=1 自动终止）
- 手机浏览器打开仓库页面就能"点一下"手动触发，也支持定时自动跑
- **免费**：私有仓库每月 2000 分钟（每月 1 号重置），每次运行约 3~10 分钟

## 需要上传到仓库的文件（都在本目录）
- `run_orders.ps1` —— 创建+监控脚本（Linux 版）
- `clickAddOrder.js`、`clickModalOK2.js`、`clickRow0.js` —— 辅助脚本
- `sample.jpg` —— 样图（上传第一个订单用，可换成你自己的样图，名字保持 sample.jpg）
- `order_config_multi.txt` —— **订单配置（链接+评论）**，改这个文件就换内容
- `.github/workflows/run.yml` —— 自动运行配置

## 部署步骤

### 第 1 步：创建私有仓库
1. 手机或电脑打开 `https://github.com/new`
2. 仓库名随便填（如 `order-auto`）
3. **必须选 Private（私有）**
4. 点 Create repository

### 第 2 步：上传文件
网页上传方式（最简单）：
1. 在仓库页面点 **Add file → Upload files**
2. 一次性把上面列的所有文件拖进去（含 `.github/workflows/run.yml`，注意隐藏文件夹）
3. 点 Commit changes
> 如果隐藏文件夹 `.github` 不好传，可以点仓库页面的 **Add file → Create new file**，手动创建路径 `.github/workflows/run.yml` 并把内容粘贴进去。

### 第 3 步：配置账号密码（Secrets）
1. 仓库页面点 **Settings** → 左侧 **Secrets and variables → Actions**
2. 点 **New repository secret**，分别添加两个：
   - `ACCOUNT` = 平台账号（19237005617）
   - `PASSWORD` = 平台密码（Ach18170606823.，结尾有句点）

### 第 4 步：填订单内容
- 编辑 `order_config_multi.txt`（点文件 → 铅笔图标编辑 → 保存），格式：
  ```
  ===链接===
  https://weixin.qq.com/sph/xxx
  ===评论===
  评论1
  评论2
  ```
- 多个链接就重复"===链接===[链接]===评论===[评论]"；想基于某订单再下一单，在评论后加一行 `===起始ID===\n订单号`

### 第 5 步：运行
- **手动运行**：仓库页面 **Actions** → 左边选 "自动下单监控" → 右边 **Run workflow** → 点绿色按钮，立刻跑一次
- **定时运行**：已配置每 2 小时自动跑一次（可改 `.github/workflows/run.yml` 里的 cron）

### 查看结果
- 运行中/完成后点开该次运行的记录，就能看到日志（登录、创建进度、监控终止记录）
- 手机浏览器也能打开 GitHub 的 Actions 页面操作和查看

## 注意事项
- 仓库必须是**私有**（账号密码在 Secrets 里，不会明文出现在代码中）
- 每次手动/定时运行用的都是 `order_config_multi.txt` 的最新内容
- 运行时监控待审=1 自动终止；运行结束即停止（非 24 小时常驻）

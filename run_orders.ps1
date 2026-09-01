# 多链接批量创建 + 自动监控（GitHub Actions / Linux 版）
# 账号密码来自环境变量 MY_ACCOUNT / MY_PASSWORD（GitHub Secrets）
# 配置：order_config_multi.txt（===链接=== / ===评论=== / 可选 ===起始ID===）
# 特点：接口定位起始订单（无需翻页）、接口监控所有页（待审=1 自动终止）
$ErrorActionPreference = 'Continue'
$dir = $PSScriptRoot

# ---------- 实时进度（写入 progress.json 并周期性推回仓库，供前端实时显示） ----------
$script:progressArr = @()
$script:lastPush = Get-Date
$progressFile = Join-Path $dir 'progress.json'
$repoEnv = $env:GITHUB_REPOSITORY
$script:pushUrl = ''
if ($repoEnv) { $script:pushUrl = "https://x-access-token:$($env:GITHUB_TOKEN)@github.com/$repoEnv.git" }
function Push-Progress {
    if (-not $script:pushUrl) { return }
    try {
        git -C $dir add -A progress.json 2>$null
        git -C $dir -c user.name="auto" -c user.email="auto@github.com" -c commit.gpgsign=false commit -m "progress" 2>$null
        git -C $dir -c http.sslVerify=false push $script:pushUrl HEAD:main 2>&1 | Out-Null
    } catch {}
}
function Add-Progress {
    param([string]$Msg)
    $script:progressArr += @{ t = (Get-Date -Format 'HH:mm:ss'); m = $Msg }
    if ($script:progressArr.Count -gt 200) { $script:progressArr = @($script:progressArr[-200..-1]) }
    $script:progressArr | ConvertTo-Json -Depth 3 | Set-Content -Path $progressFile -Encoding UTF8
    $now = Get-Date
    if (($now - $script:lastPush).TotalSeconds -ge 30 -and $script:pushUrl) {
        $script:lastPush = $now
        Push-Progress
    }
}

# 每次运行开始：先清空旧进度日志，避免手机端显示上一次的内容
Add-Progress '开始运行'
Push-Progress

if (-not $env:MY_ACCOUNT -or -not $env:MY_PASSWORD) {
    Write-Host '[错误] 缺少 MY_ACCOUNT / MY_PASSWORD 环境变量（请在 GitHub Secrets 配置）'
    exit 1
}
$account = $env:MY_ACCOUNT.Trim()
$password = $env:MY_PASSWORD
$title = '复制悬赏要求内容评论'
$rate = '150'
$buy = '10'
# 控件速（下单间隔）：优先读取 order_rate.txt（手机网页提交的数值），缺失则用默认 150
$rateFile = Join-Path $dir 'order_rate.txt'
if (Test-Path $rateFile) {
    $rt = ([IO.File]::ReadAllText($rateFile, [Text.Encoding]::UTF8)).Trim()
    if ($rt -match '^\d+$' -and [int]$rt -ge 1) { $rate = $rt }
}

# ---------- agent-browser 命令封装 ----------
function Invoke-AB {
    param([string[]]$ArgsList)
    & agent-browser @ArgsList *> $null
}
function Eval-AB {
    param([string]$Base64Js)
    return (& agent-browser eval -b $Base64Js 2>&1 | Out-String).Trim()
}

# ---------- 网络自检 ----------
Write-Host '== 网络自检 =='
try {
    $netRes = Invoke-WebRequest -Uri 'https://imt.tiankongfeiji.cn/customer/login.html' -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    Write-Host ('平台可访问（状态 ' + $netRes.StatusCode + '）')
} catch {
    Write-Host ('[错误] 网络无法访问平台：' + $_.Exception.Message)
    exit 1
}

# ---------- 读取多链接配置 ----------
$cfg = Join-Path $dir 'order_config_multi.txt'
# 手动提交窗口：如果填了链接，用它生成配置（单链接+多条评论）；否则用仓库里的配置文件
if ($env:INPUT_LINK) {
    $inComments = @($env:INPUT_COMMENTS -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($inComments.Count -eq 0) {
        Write-Host '[错误] 手动提交时评论不能为空（多条评论用 | 分隔）'
        exit 1
    }
    $cfgText = "===链接===`r`n" + $env:INPUT_LINK.Trim() + "`r`n===评论===`r`n" + ($inComments -join "`r`n")
    [IO.File]::WriteAllText($cfg, $cfgText)
    Write-Host ('使用手动提交的配置（评论 ' + $inComments.Count + ' 条）')
}
if (-not (Test-Path $cfg)) {
    Write-Host '[错误] 找不到 order_config_multi.txt'
    exit 1
}
$raw = [IO.File]::ReadAllLines($cfg, [Text.Encoding]::UTF8)
$groups = @()
$cur = $null
$state = ''
foreach ($line in $raw) {
    $t = $line.Trim()
    if ($t -eq '') { continue }
    if ($t -eq '===链接===') {
        if ($cur -ne $null -and $cur.Link -ne '' -and $cur.Comments.Count -gt 0) { $groups += $cur }
        $cur = @{ Link = ''; StartId = ''; Comments = @() }
        $state = 'link'
    } elseif ($t -eq '===起始ID===') {
        $state = 'startid'
    } elseif ($t -eq '===评论===') {
        $state = 'comments'
    } else {
        if ($cur -eq $null) { continue }
        if ($state -eq 'link') { $cur.Link = $t }
        elseif ($state -eq 'startid') { $cur.StartId = $t }
        elseif ($state -eq 'comments') { $cur.Comments += $t }
    }
}
if ($cur -ne $null -and $cur.Link -ne '' -and $cur.Comments.Count -gt 0) { $groups += $cur }
if ($groups.Count -eq 0) { Write-Host '[错误] order_config_multi.txt 中没有有效组'; exit 1 }
Write-Host ('共 ' + $groups.Count + ' 组链接')
for ($g = 0; $g -lt $groups.Count; $g++) {
    $sidInfo = ''
    if ($groups[$g].StartId -ne '') { $sidInfo = '（起始订单: ' + $groups[$g].StartId + '）' }
    Write-Host ('  组' + ($g + 1) + ': ' + $groups[$g].Link + $sidInfo + '（评论 ' + $groups[$g].Comments.Count + ' 条）')
}

# ---------- 辅助 JS (base64) ----------
$jsClickAdd = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText((Join-Path $dir 'clickAddOrder.js'), [Text.Encoding]::UTF8)))
$jsClickOk  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText((Join-Path $dir 'clickModalOK2.js'), [Text.Encoding]::UTF8)))
$jsRow0     = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText((Join-Path $dir 'clickRow0.js'), [Text.Encoding]::UTF8)))
$jsPageReady = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("(function(){var e=document.getElementById('url');return (e)?'ready':'no'})()"))
$jsGetUrl = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("location.href"))

# 接口定位起始订单并写入 localStorage
$jsLocateHead = "(function(id){var xhr=new XMLHttpRequest();xhr.open('POST','/capi/order/orderList',false);xhr.setRequestHeader('Content-Type','application/json; charset=utf-8');xhr.setRequestHeader('login-un',getStorage('un_customer'));xhr.setRequestHeader('login-token',getStorage('token_customer'));xhr.send(JSON.stringify({orderId:id}));var r=JSON.parse(xhr.responseText);var vo=r.result&&r.result.list&&r.result.list[0];if(!vo)return 'not-found';setStorage('add_order_again_info',JSON.stringify(vo));return 'ok:'+vo.id;})('"
$jsLocateEnd = "')"

# 接口监控 JS（详细版）：待审=submitNum-passNum-notPassNum，>=1 自动终止+二次验证；登录状态检测；分页循环 return 在循环外
$jsMon = "(function(){var out={total:0,pages:0,found:[],loginOk:true,err:''};var uid=(typeof getStorage==='function'&&getStorage('uid'))||'0';function api(url,data){var xhr=new XMLHttpRequest();xhr.open('POST','/capi'+url,false);xhr.setRequestHeader('Content-Type','application/json; charset=utf-8');xhr.setRequestHeader('Accept','application/json, text/javascript, */*; q=0.01');xhr.setRequestHeader('login-un',getStorage('un_customer'));xhr.setRequestHeader('login-token',getStorage('token_customer'));xhr.setRequestHeader('login-uid',uid);xhr.setRequestHeader('platform',typeof app==='undefined'?0:1);xhr.setRequestHeader('X-Requested-With','XMLHttpRequest');xhr.send(JSON.stringify(data));try{return JSON.parse(xhr.responseText);}catch(e){return {code:-1,raw:xhr.responseText};}}for(var pg=1;pg<=25;pg++){out.pages=pg;var r=api('/order/orderList',{pageNum:pg,pageSize:100});if(r.code!==0||!r.result){var mm=(r.msg||'')+' code='+r.code;if(r.code===50||r.code===401||r.code===403||/登录|token|过期|失效|未登录|授权/i.test(mm)){out.loginOk=false;out.err=mm;}else{out.err='page'+pg+':code'+r.code+' msg='+(r.msg||'');}break;}var list=r.result.list||[];out.total+=list.length;if(list.length===0)break;for(var i=0;i<list.length;i++){var v=list[i];if(v.title!=='复制悬赏要求内容评论')continue;var pend=(parseInt(v.submitNum,10)||0)-(parseInt(v.passNum,10)||0)-(parseInt(v.notPassNum,10)||0);var item={id:v.id,submit:v.submitNum,pass:v.passNum,notPass:v.notPassNum,pend:pend,status:v.orderStatus};if(pend>=1&&v.orderStatus===20){var sr=api('/order/stopOrder',{id:v.id,pageSize:20,pageNum:1});item.stopResp=JSON.stringify(sr);if(sr.code===0){item.stopResult='ok';var wt=Date.now()+1500;while(Date.now()<wt){}var vr=api('/order/orderList',{pageNum:1,pageSize:100});var vl=(vr.result&&vr.result.list)||[];var vv=null;for(var j2=0;j2<vl.length;j2++){if(String(vl[j2].id)===String(v.id)){vv=vl[j2];break;}}item.verify=vv?('status='+vv.orderStatus+',pend='+((vv.submitNum||0)-(vv.passNum||0)-(vv.notPassNum||0))):'not-found';}else{item.stopResult='fail:'+sr.code;}}out.found.push(item);}}return JSON.stringify(out);})()"
$bMon = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($jsMon))

# ---------- 监控轮询（详细日志 + 进度推送 + 登录状态检测） ----------
function Invoke-MonitorRound {
    param([int]$RoundNo, [switch]$IsInCreate)
    $r = Eval-AB $bMon
    try { $o = $r | ConvertFrom-Json } catch { $o = $null }
    # agent-browser eval 返回带引号的 JSON 字符串，需二次解析才能得到对象
    if ($o -is [string]) { try { $o = $o | ConvertFrom-Json } catch { $o = $null } }
    $ts = Get-Date -Format 'HH:mm:ss'
    $tag = if ($IsInCreate) { '创建后监控' } else { '监控' }
    if ($null -eq $o) {
        Write-Host ("[" + $ts + "] " + $tag + "：结果解析失败（" + $r + "）")
        Add-Progress ($tag + ': 结果解析失败')
        return @{ ok = $false; loginFail = $false }
    }
    if (-not $o.loginOk) {
        Write-Host ("[" + $ts + "] " + $tag + "：登录状态异常 " + $o.err)
        Add-Progress ($tag + ': 登录状态异常 ' + $o.err)
        return @{ ok = $true; loginFail = $true }
    }
    $log = ("[" + $ts + "] " + $tag + "：查询 " + $o.pages + " 页，共 " + $o.found.Count + " 个目标订单")
    if ($o.err) { $log += (" | 接口异常:" + $o.err) }
    # 只取执行中（status=20）且有待审（pending>=1）的订单；已终止订单（status=50）pending 残留但不再处理
    $pendOrders = @($o.found | Where-Object { $_.pend -ge 1 -and $_.status -eq 20 })
    if ($pendOrders.Count -eq 0) {
        $log += "，当前无待审"
        Write-Host $log
        Add-Progress ($tag + ': ' + $log)
        return @{ ok = $true; loginFail = $false }
    }
    Write-Host $log
    Write-Host ("[" + $ts + "] 发现 " + $pendOrders.Count + " 个待审订单")
    $log += (" | 发现 " + $pendOrders.Count + " 个待审")
    foreach ($f in $pendOrders) {
        Write-Host ("[" + $ts + "] 订单ID：" + $f.id + " submit=" + $f.submit + " pass=" + $f.pass + " notPass=" + $f.notPass + " pending=" + $f.pend)
        Write-Host ("[" + $ts + "] 执行 stopOrder")
        if ($f.stopResult -eq 'ok') {
            Write-Host ("[" + $ts + "] stopOrder 响应：code=0")
            Write-Host ("[" + $ts + "] 二次验证：" + $f.verify)
            Write-Host ("[" + $ts + "] 自动停止成功")
            $log += (" | " + $f.id + " 已停止")
        } else {
            Write-Host ("[" + $ts + "] stopOrder 响应：" + $f.stopResp)
            Write-Host ("[" + $ts + "] 停止结果：失败(" + $f.stopResult + ")")
            $log += (" | " + $f.id + " 停止失败")
        }
    }
    Add-Progress ($tag + ': ' + $log)
    return @{ ok = $true; loginFail = $false }
}

# ---------- 登录（带验证和重试） ----------
function Login-Once {
    Invoke-AB @('open', 'https://imt.tiankongfeiji.cn/customer/login.html')
    Start-Sleep 3
    $jsLoginReady = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("(function(){var u=document.getElementById('un');var p=document.getElementById('pwd');return (u&&p)?'ready':'no'})()"))
    $loginReady = 'no'
    for ($k = 0; $k -lt 10; $k++) {
        Start-Sleep 2
        $loginReady = Eval-AB $jsLoginReady
        if ($loginReady -match 'ready') { break }
    }
    if ($loginReady -match 'ready') { Write-Host '登录框已就绪' } else { Write-Host '[警告] 登录框未出现' }
    $jsLoginCheck = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("JSON.stringify({u:document.getElementById('un').value,pLen:document.getElementById('pwd').value.length})"))
    for ($try = 1; $try -le 3; $try++) {
        Invoke-AB @('find', 'placeholder', '账号 / 手机号', 'fill', $account)
        Invoke-AB @('find', 'placeholder', '密码', 'fill', $password)
        Start-Sleep 2
        $checkRes = Eval-AB $jsLoginCheck
        Write-Host ('填写检查: ' + $checkRes)
        if ($checkRes -match [regex]::Escape($account)) { Write-Host '账号已填写'; break }
        Write-Host ('第 ' + $try + ' 次填写失败，重试…')
        Start-Sleep 3
    }
    Invoke-AB @('find', 'role', 'button', 'click', '--name', '登录')
    Start-Sleep 18
    $loginUrl = Eval-AB $jsGetUrl
    if ($loginUrl -notmatch 'login.html') { return $true }
    # 诊断：抓登录失败时的页面内容
    $jsDiag = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("(function(){var b=(document.body.innerText||'');return JSON.stringify({url:location.href,tail:b.slice(-180),cap:Array.from(document.querySelectorAll('img')).filter(function(e){var s=e.src||'';return s.indexOf('captcha')>=0||s.indexOf('verify')>=0||s.indexOf('code')>=0;}).length})})()"))
    $diag = Eval-AB $jsDiag
    Write-Host ('登录失败诊断: ' + $diag)
    return $false
}

$loggedIn = $false
for ($attempt = 1; $attempt -le 3; $attempt++) {
    Write-Host ('== 登录（第 ' + $attempt + ' 次尝试） ==')
    $loggedIn = Login-Once
    if ($loggedIn) { Write-Host '登录成功'; Add-Progress '登录成功'; break }
    Write-Host '[警告] 登录未成功，重新尝试…'
}
if (-not $loggedIn) {
    Write-Host '[错误] 多次登录失败，请检查账号密码'
    Add-Progress '登录失败'
    Push-Progress
    exit 1
}

# ---------- 逐组创建 ----------
$totalCreated = 0
for ($g = 0; $g -lt $groups.Count; $g++) {
    $grp = $groups[$g]
    $comments = @($grp.Comments)
    Write-Host ('===== 组' + ($g + 1) + ': ' + $grp.Link + '（' + $comments.Count + ' 条评论） =====')

    $firstId = ''
    $startIdx = 0
    if ($grp.StartId -ne '') {
        $firstId = $grp.StartId
        $startIdx = 0
        Write-Host ('-- 使用指定起始订单 ' + $firstId + '，全部评论基于它再下一单 --')
    } else {
        $startIdx = 1
        Write-Host ('-- 组内第 1 个订单（完整填写） --')
        Invoke-AB @('open', 'https://imt.tiankongfeiji.cn/customer/order_add.html')
        $pageReady = 'no'
        for ($k = 0; $k -lt 8; $k++) {
            Start-Sleep 2
            $pageReady = Eval-AB $jsPageReady
            if ($pageReady -match 'ready') { break }
        }
        if ($pageReady -notmatch 'ready') { Write-Host '[警告] 订单页加载超时，继续尝试…' }
        Invoke-AB @('fill', '#url', $grp.Link)
        Invoke-AB @('fill', '#title', $title)
        Invoke-AB @('fill', '#taskRequire', $comments[0])
        Invoke-AB @('fill', '#rateLimit', $rate)
        Invoke-AB @('fill', '#buyNum', $buy)
        Write-Host ('评论内容: ' + $comments[0])
        Add-Progress ('创建订单: ' + $comments[0])
        Invoke-AB @('upload', '#fs1File', (Join-Path $dir 'sample.jpg'))
        Start-Sleep 4
        $null = Eval-AB $jsClickAdd
        Start-Sleep 2
        $null = Eval-AB $jsClickOk
        Start-Sleep 5

        Invoke-AB @('open', 'https://imt.tiankongfeiji.cn/customer/order_list.html')
        $jsRow0Exists = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("(function(){var els=Array.from(document.querySelectorAll('[onclick]')).filter(function(e){return (e.getAttribute('onclick')||'').indexOf('addOrderAgain')===0});return els.length>0})()"))
        $ready = 'false'
        for ($k = 0; $k -lt 12; $k++) {
            Start-Sleep 2
            $ready = Eval-AB $jsRow0Exists
            if ($ready -match 'true') { Write-Host '列表已就绪'; break }
        }
        $null = Eval-AB $jsRow0
        Start-Sleep 5
        $url = Eval-AB $jsGetUrl
        $m = [regex]::Match($url, 'orderId=(\d+)')
        if ($m.Success) { $firstId = $m.Groups[1].Value }
        if ($firstId -eq '') {
            Write-Host ('[警告] 无法获取组' + ($g + 1) + '第一个订单 ID，跳过本组')
            continue
        }
        Write-Host ('第一个订单 ID: ' + $firstId)
        $totalCreated++
    }

    $null = Invoke-MonitorRound -IsInCreate

    for ($i = $startIdx; $i -lt $comments.Count; $i++) {
        Write-Host ('-- 组' + ($g + 1) + ' 第 ' + ($i + 1) + ' 个订单（基于 ' + $firstId + ' 再下一单） --')
        $jsLocate = $jsLocateHead + $firstId + $jsLocateEnd
        $bLocate = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($jsLocate))
        $locRes = Eval-AB $bLocate
        if ($locRes -notmatch 'ok:') { Write-Host ('[警告] 接口定位起始订单失败: ' + $locRes + '，停止本组'); break }
        Invoke-AB @('open', ('https://imt.tiankongfeiji.cn/customer/order_add.html?orderId=' + $firstId))
        $pageReady = 'no'
        for ($k = 0; $k -lt 8; $k++) {
            Start-Sleep 2
            $pageReady = Eval-AB $jsPageReady
            if ($pageReady -match 'ready') { break }
        }
        if ($pageReady -notmatch 'ready') { Write-Host '[警告] 预填页加载超时，继续尝试…' }
        # 关键：预填页带出的是原订单链接，必须强制覆盖为用户填的视频号链接
        Invoke-AB @('fill', '#url', $grp.Link)
        Invoke-AB @('fill', '#taskRequire', $comments[$i])
        Invoke-AB @('fill', '#buyNum', $buy)
        Write-Host ('评论内容: ' + $comments[$i])
        Add-Progress ('创建订单: ' + $comments[$i])
        $null = Eval-AB $jsClickAdd
        Start-Sleep 2
        $null = Eval-AB $jsClickOk
        $totalCreated++
        $null = Invoke-MonitorRound -IsInCreate
        Start-Sleep 4
    }
}

Write-Host ('本次运行完成，共创建 ' + $totalCreated + ' 个订单。')
Add-Progress ('本次运行完成，共创建 ' + $totalCreated + ' 个订单')
Write-Host '== 进入持续监控（每 10 秒轮询，待审>=1 自动终止并验证；停止监控请在 Actions 页面点 Cancel） =='
# 切到订单列表页，确保页面上下文（getStorage/getUid 等）可用
Invoke-AB @('open', 'https://imt.tiankongfeiji.cn/customer/order_list.html')
Start-Sleep 4
$mCount = 0
$mLoginFail = 0
while ($true) {
    $mCount++
    $res = Invoke-MonitorRound -RoundNo $mCount
    if ($res.loginFail) {
        $mLoginFail++
        if ($mLoginFail -ge 3) {
            Write-Host '[监控] 登录状态失效，尝试重新登录…'
            $relogin = $false
            for ($ra = 1; $ra -le 3; $ra++) {
                $relogin = Login-Once
                if ($relogin) { break }
            }
            if ($relogin) {
                Write-Host '[监控] 重新登录成功，继续监控'
                Add-Progress '监控: 重新登录成功'
                $mLoginFail = 0
                Invoke-AB @('open', 'https://imt.tiankongfeiji.cn/customer/order_list.html')
                Start-Sleep 4
            } else {
                Write-Host '[错误] 登录状态已失效且重新登录失败，终止任务'
                Add-Progress '登录状态已失效，需要重新登录'
                Push-Progress
                exit 1
            }
        }
    } else {
        $mLoginFail = 0
    }
    Start-Sleep 10
}

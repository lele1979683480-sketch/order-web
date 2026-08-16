# 多链接批量创建 + 自动监控（GitHub Actions / Linux 版）
# 账号密码来自环境变量 MY_ACCOUNT / MY_PASSWORD（GitHub Secrets）
# 配置：order_config_multi.txt（===链接=== / ===评论=== / 可选 ===起始ID===）
# 特点：接口定位起始订单（无需翻页）、接口监控所有页（待审=1 自动终止）
$ErrorActionPreference = 'Continue'
$dir = $PSScriptRoot

if (-not $env:MY_ACCOUNT -or -not $env:MY_PASSWORD) {
    Write-Host '[错误] 缺少 MY_ACCOUNT / MY_PASSWORD 环境变量（请在 GitHub Secrets 配置）'
    exit 1
}
$account = $env:MY_ACCOUNT.Trim()
$password = $env:MY_PASSWORD
$title = '复制悬赏要求内容评论'
$rate = '150'
$buy = '10'

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

# 接口监控 JS
$jsMon = "(function(){var out=[];function api(url,data){var xhr=new XMLHttpRequest();xhr.open('POST','/capi'+url,false);xhr.setRequestHeader('Content-Type','application/json; charset=utf-8');xhr.setRequestHeader('login-un',getStorage('un_customer'));xhr.setRequestHeader('login-token',getStorage('token_customer'));xhr.send(JSON.stringify(data));try{return JSON.parse(xhr.responseText);}catch(e){return {code:-1};}}for(var pg=1;pg<=15;pg++){var r=api('/order/orderList',{pageNum:pg,pageSize:20});var list=r.result&&r.result.list||[];if(list.length===0)break;for(var i=0;i<list.length;i++){var v=list[i];if(v.title!=='复制悬赏要求内容评论')continue;var ap=v.auditProgress||'0 / 0';var parts=ap.split('/');var pending=-1;if(parts.length>=2){pending=parseInt(parts[1].trim(),10);if(isNaN(pending))pending=-1;}if(pending===1){var sr=api('/order/stopOrder',{id:v.id});out.push('stopped:'+v.id+(sr.code===0?'(ok)':'(code'+sr.code+')'));}}}return JSON.stringify({action:out});})()"
$bMon = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($jsMon))

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
    if ($loggedIn) { Write-Host '登录成功'; break }
    Write-Host '[警告] 登录未成功，重新尝试…'
}
if (-not $loggedIn) {
    Write-Host '[错误] 多次登录失败，请检查账号密码'
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

    $rMon = Eval-AB $bMon
    if ($rMon -match 'stopped') { Write-Host ('监控终止: ' + $rMon) }

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
        Invoke-AB @('fill', '#taskRequire', $comments[$i])
        Invoke-AB @('fill', '#buyNum', $buy)
        $null = Eval-AB $jsClickAdd
        Start-Sleep 2
        $null = Eval-AB $jsClickOk
        $totalCreated++
        $rMon = Eval-AB $bMon
        if ($rMon -match 'stopped') { Write-Host ('监控终止: ' + $rMon) }
        Start-Sleep 4
    }
}

Write-Host ('本次运行完成，共创建 ' + $totalCreated + ' 个订单。')

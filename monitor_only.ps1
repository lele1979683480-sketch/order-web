# imt 评论订单定时监控（只扫描 + 自动终止，绝不创建订单）
# 用途：由 GitHub Actions 定时触发（每 30 分钟），扫描"复制悬赏要求内容评论"订单，
#       发现 待审>=1 且 状态=执行中(20) 的订单，自动终止并二次验证。
# 账号密码来自环境变量 MY_ACCOUNT / MY_PASSWORD（GitHub Secrets）
$ErrorActionPreference = 'Continue'
$dir = $PSScriptRoot

# 浏览器环境：socket 目录指向脚本目录；显式置空代理
$env:AGENT_BROWSER_SOCKET_DIR = Join-Path $dir '.ab'
if (-not (Test-Path $env:AGENT_BROWSER_SOCKET_DIR)) { New-Item -ItemType Directory -Path $env:AGENT_BROWSER_SOCKET_DIR -Force | Out-Null }
$env:AGENT_BROWSER_PROXY = ''

function Invoke-AB {
    param([string[]]$ArgsList)
    & agent-browser @ArgsList *> $null
}
function Eval-AB {
    param([string]$Base64Js)
    return (& agent-browser eval -b $Base64Js 2>&1 | Out-String).Trim()
}

$targetTitle = '复制悬赏要求内容评论'
$maxPages = 40
$runMinutes = 350      # 单次运行持续时长（分钟）：跑满约 5 小时 50 分后自动结束，靠下一班接续
$intervalSec = 60      # 每轮扫描间隔（秒）

if (-not $env:MY_ACCOUNT -or -not $env:MY_PASSWORD) {
    Write-Host '[错误] 缺少 MY_ACCOUNT / MY_PASSWORD 环境变量（请在 GitHub Secrets 配置）'
    exit 1
}
$account = $env:MY_ACCOUNT.Trim()
$password = $env:MY_PASSWORD

# ---------- 网络自检 ----------
Write-Host '== 网络自检 =='
try {
    $netRes = Invoke-WebRequest -Uri 'https://imt.tiankongfeiji.cn/customer/login.html' -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    Write-Host ('平台可访问（状态 ' + $netRes.StatusCode + '）')
} catch {
    Write-Host ('[错误] 网络无法访问平台：' + $_.Exception.Message)
    exit 1
}

# ---------- 监控 JS：扫描全部订单 -> 待审>=1 且执行中则终止 -> 二次验证 ----------
$jsMon = "(function(){var out={total:0,pages:0,found:[],loginOk:true,err:''};var uid=(typeof getStorage==='function'&&getStorage('uid'))||'0';function api(url,data){var xhr=new XMLHttpRequest();xhr.open('POST','/capi'+url,false);xhr.setRequestHeader('Content-Type','application/json; charset=utf-8');xhr.setRequestHeader('Accept','application/json, text/javascript, */*; q=0.01');xhr.setRequestHeader('login-un',getStorage('un_customer'));xhr.setRequestHeader('login-token',getStorage('token_customer'));xhr.setRequestHeader('login-uid',uid);xhr.setRequestHeader('platform',typeof app==='undefined'?0:1);xhr.setRequestHeader('X-Requested-With','XMLHttpRequest');xhr.send(JSON.stringify(data));try{return JSON.parse(xhr.responseText);}catch(e){return {code:-1,raw:xhr.responseText};}}for(var pg=1;pg<=" + $maxPages + ";pg++){out.pages=pg;var r=api('/order/orderList',{pageNum:pg,pageSize:100});if(r.code!==0||!r.result){var mm=(r.msg||'')+' code='+r.code;if(r.code===50||r.code===401||r.code===403||/登录|token|过期|失效|未登录|授权/i.test(mm)){out.loginOk=false;out.err=mm;}else{out.err='page'+pg+':code'+r.code+' msg='+(r.msg||'');}break;}var list=r.result.list||[];out.total+=list.length;if(list.length===0)break;for(var i=0;i<list.length;i++){var v=list[i];if(v.title!=='" + $targetTitle + "')continue;var pend=(parseInt(v.submitNum,10)||0)-(parseInt(v.passNum,10)||0)-(parseInt(v.notPassNum,10)||0);var item={id:v.id,submit:v.submitNum,pass:v.passNum,notPass:v.notPassNum,pend:pend,status:v.orderStatus};if(pend>=1&&v.orderStatus===20){var sr=api('/order/stopOrder',{id:v.id,pageSize:20,pageNum:1});item.stopResp=JSON.stringify(sr);if(sr.code===0){item.stopResult='ok';var wt=Date.now()+1500;while(Date.now()<wt){}var vr=api('/order/orderList',{orderId:v.id});var vl=(vr.result&&vr.result.list)||[];var vv=(vl&&vl.length)?vl[0]:null;item.verify=vv?('status='+vv.orderStatus):'not-found';}else{item.stopResult='fail:'+sr.code;}}out.found.push(item);}}return JSON.stringify(out);})()"
$bMon = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($jsMon))

# ---------- 登录相关 JS ----------
$jsGetUrl = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("location.href"))
$jsLoginReady = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("(function(){var u=document.getElementById('un');var p=document.getElementById('pwd');return (u&&p)?'ready':'no'})()"))
$jsLoginCheck = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("JSON.stringify({u:document.getElementById('un').value,pLen:document.getElementById('pwd').value.length})"))

function Login-Once {
    Invoke-AB @('open', 'https://imt.tiankongfeiji.cn/customer/login.html')
    Start-Sleep 3
    $loginReady = 'no'
    for ($k = 0; $k -lt 10; $k++) {
        Start-Sleep 2
        $loginReady = Eval-AB $jsLoginReady
        if ($loginReady -match 'ready') { break }
    }
    if ($loginReady -match 'ready') { Write-Host '登录框已就绪' } else { Write-Host '[警告] 登录框未出现' }
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
    Write-Host ('登录失败，当前地址: ' + $loginUrl)
    return $false
}

# ---------- 执行一轮监控 ----------
function Invoke-MonitorRound {
    Invoke-AB @('open', 'https://imt.tiankongfeiji.cn/customer/order_list.html')
    Start-Sleep 5
    Invoke-AB @('wait', '3000')
    $r = Eval-AB $bMon
    try { $o = $r | ConvertFrom-Json } catch { $o = $null }
    if ($o -is [string]) { try { $o = $o | ConvertFrom-Json } catch { $o = $null } }
    return $o
}

$loggedIn = $false
for ($attempt = 1; $attempt -le 3; $attempt++) {
    Write-Host ('== 登录（第 ' + $attempt + ' 次尝试） ==')
    $loggedIn = Login-Once
    if ($loggedIn) { Write-Host '登录成功'; break }
    Write-Host '[警告] 登录未成功，重试…'
}
if (-not $loggedIn) {
    Write-Host '[错误] 多次登录失败，请检查账号密码（Secrets: ACCOUNT / PASSWORD）'
    exit 1
}

# ---------- 长班次循环：每 $intervalSec 秒扫一轮，持续 $runMinutes 分钟 ----------
$endTime = (Get-Date).AddMinutes($runMinutes)
$round = 0
$failStreak = 0
Write-Host ('开始长班次监控：每 ' + $intervalSec + ' 秒扫一轮，持续 ' + $runMinutes + ' 分钟')

while ((Get-Date) -lt $endTime) {
    $round++
    $roundStart = Get-Date
    $ts = Get-Date -Format 'HH:mm:ss'
    $o = Invoke-MonitorRound

    if ($null -eq $o) {
        $failStreak++
        Write-Host ('[' + $ts + '] 轮次 ' + $round + '：结果解析失败（第 ' + $failStreak + ' 次）')
        if ($failStreak -ge 3) {
            Write-Host '连续失败，尝试重新登录…'
            if (Login-Once) { Write-Host '重新登录成功' } else { Write-Host '[警告] 重新登录失败' }
            $failStreak = 0
        }
    } elseif ($o.loginOk -eq $false) {
        $failStreak = 0
        Write-Host ('[' + $ts + '] 轮次 ' + $round + '：登录失效（' + $o.err + '）→ 重新登录')
        if (Login-Once) { Write-Host '重新登录成功' } else { Write-Host '[警告] 重新登录失败，下一轮再试' }
    } else {
        $failStreak = 0
        $pendOrders = @($o.found | Where-Object { $_.pend -ge 1 -and $_.status -eq 20 })
        if ($pendOrders.Count -eq 0) {
            Write-Host ('[' + $ts + '] 轮次 ' + $round + '：扫 ' + $o.pages + ' 页 / ' + $o.total + ' 条，命中 ' + $o.found.Count + ' 条，无待审')
        } else {
            Write-Host ('[' + $ts + '] 轮次 ' + $round + '：发现 ' + $pendOrders.Count + ' 个待审订单，已自动终止')
            foreach ($f in $pendOrders) {
                Write-Host ('    订单 ' + $f.id + ' | pending=' + $f.pend + ' | stopOrder=' + $f.stopResult + ' | 二次验证=' + $f.verify)
            }
        }
        if ($o.err) { Write-Host ('    接口提示: ' + $o.err) }
    }

    # 补齐到固定间隔，避免过于频繁地打平台接口
    $elapsed = ((Get-Date) - $roundStart).TotalSeconds
    if ($elapsed -lt $intervalSec) { Start-Sleep -Seconds ([int]($intervalSec - $elapsed)) }
}

Write-Host ('长班次结束：共执行 ' + $round + ' 轮监控，本次运行退出，等下一班接续')

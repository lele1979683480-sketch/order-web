# 诊断：查询订单字段（不创建任何订单，只用于确认"待审"字段）
$ErrorActionPreference = 'Continue'
function Invoke-AB { param([string[]]$ArgsList) & agent-browser @ArgsList *> $null }
function Eval-AB { param([string]$Base64Js) return (& agent-browser eval -b $Base64Js 2>&1 | Out-String).Trim() }

Write-Host '== 登录平台 =='
Invoke-AB @('open', 'https://imt.tiankongfeiji.cn/customer/login.html')
Start-Sleep 3
$jsLoginReady = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("(function(){var u=document.getElementById('un');var p=document.getElementById('pwd');return (u&&p)?'ready':'no'})()"))
$ready = 'no'
for ($k = 0; $k -lt 10; $k++) {
    Start-Sleep 2
    $ready = Eval-AB $jsLoginReady
    if ($ready -match 'ready') { break }
}
Invoke-AB @('find', 'placeholder', '账号 / 手机号', 'fill', $env:MY_ACCOUNT)
Invoke-AB @('find', 'placeholder', '密码', 'fill', $env:MY_PASSWORD)
Start-Sleep 2
Invoke-AB @('find', 'role', 'button', 'click', '--name', '登录')
Start-Sleep 18

Write-Host '== 查询订单字段 =='
$jsQ = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("(function(){function api(url,data){var xhr=new XMLHttpRequest();xhr.open('POST','/capi'+url,false);xhr.setRequestHeader('Content-Type','application/json; charset=utf-8');xhr.setRequestHeader('login-un',getStorage('un_customer'));xhr.setRequestHeader('login-token',getStorage('token_customer'));xhr.send(JSON.stringify(data));try{return JSON.parse(xhr.responseText);}catch(e){return {code:-1};}}var out=[];var r=api('/order/orderList',{pageNum:1,pageSize:10});(r.result.list||[]).forEach(function(v){out.push({id:v.id,toExamine:v.toExamine,orderStatus:v.orderStatus,submit:v.submitNum,pass:v.passNum,notPass:v.notPassNum,receive:v.receiveNum});});var t=api('/order/orderList',{orderId:'2089919699160731648'});var v2=t.result&&t.result.list&&t.result.list[0];return JSON.stringify({recent10:out,target:v2||'none'});})()"))
$res = Eval-AB $jsQ
Write-Host '===== 诊断结果 ====='
Write-Host $res

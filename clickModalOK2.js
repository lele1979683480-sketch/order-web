(function(){
  function visible(el){
    var r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }
  var btns = Array.from(document.querySelectorAll('.modal.in button, .modal.show button, button, [onclick="modalConfirm()"]'));
  var ok = null;
  for (var i=0;i<btns.length;i++){
    var t=(btns[i].innerText||btns[i].getAttribute('onclick')||'').trim();
    if ((t==='确定' || t==='modalConfirm()') && visible(btns[i])){ ok=btns[i]; break; }
  }
  if (ok){ ok.click(); return 'clicked-visible-确定'; }
  return 'no-visible-ok';
})()

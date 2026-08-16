(function(){
  var els = Array.from(document.querySelectorAll('[onclick]')).filter(function(e){return (e.getAttribute('onclick')||'').indexOf('addOrderAgain')===0});
  if (els[0]){ els[0].click(); return 'clicked-row0'; }
  return 'not-found:'+els.length;
})()

(function(){
  var div = Array.from(document.querySelectorAll('[onclick]')).find(function(e){return e.getAttribute('onclick')==='addOrder()'});
  if (div){ div.click(); return 'clicked-addOrder'; }
  return 'addOrder-not-found';
})()

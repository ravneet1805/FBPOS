self.addEventListener('install',()=>self.skipWaiting());
self.addEventListener('activate',event=>event.waitUntil(self.clients.claim()));
self.addEventListener('push',event=>{
  let data={title:'FOR BROTHERS',body:'A new update is available.'};
  try{data={...data,...event.data.json()}}catch{}
  const pendingUpi=data.title?.startsWith('UPI PAYMENT');
  const options={body:data.body,icon:'/icon-192.png',badge:'/icon-192.png',tag:data.tag,data:{url:data.url||'/',saleId:data.saleId},vibrate:pendingUpi?[150,80,150]:undefined,requireInteraction:pendingUpi||false};
  if(data.actions?.length)options.actions=data.actions;
  const notification=self.registration.showNotification(data.title,options).catch(()=>{const fallback={...options};delete fallback.actions;delete fallback.vibrate;return self.registration.showNotification(data.title,fallback)});
  event.waitUntil(Promise.all([
    notification,
    pendingUpi&&data.saleId?self.clients.matchAll({type:'window',includeUncontrolled:true}).then(list=>list.forEach(client=>client.postMessage({type:'upi-pending',saleId:data.saleId}))):Promise.resolve()
  ]));
});
self.addEventListener('notificationclick',event=>{
  event.notification.close();
  const url=event.notification.data?.url||'/';
  event.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(async list=>{
    for(const client of list){if('focus'in client){await client.navigate(url);return client.focus()}}
    return self.clients.openWindow(url);
  }));
});

import { NextRequest, NextResponse } from 'next/server';
import webpush from 'web-push';
import { admin } from '@/lib/admin';

export async function POST(req:NextRequest){
  const token=req.headers.get('authorization')?.replace(/^Bearer\s+/i,'');
  if(!token)return NextResponse.json({error:'Unauthorized'},{status:401});
  const {data:{user},error:authError}=await admin.auth.getUser(token);
  if(authError||!user)return NextResponse.json({error:'Unauthorized'},{status:401});
  if(!process.env.VAPID_PUBLIC_KEY||!process.env.VAPID_PRIVATE_KEY)return NextResponse.json({error:'Push is not configured'},{status:503});
  const {saleId}=await req.json();
  const {data:existingSale,error:saleLookupError}=await admin.from('sales').select('id,order_number').eq('id',saleId).maybeSingle();
  if(saleLookupError)return NextResponse.json({error:'Order number schema is unavailable. Apply Supabase migration 007.'},{status:503});
  if(!existingSale)return NextResponse.json({error:'Sale not found'},{status:404});
  if(!existingSale.order_number)return NextResponse.json({error:'Order number is unavailable. Apply Supabase migration 007.'},{status:503});
  const {data:subs,error:subscriptionError}=await admin.from('push_subscriptions').select('id,subscription');
  if(subscriptionError)return NextResponse.json({error:'Could not load notification subscriptions'},{status:503});
  if(!subs?.length)return NextResponse.json({ok:true,sent:0});
  const {data:claimed,error:claimError}=await admin.rpc('claim_sale_notification',{p_sale_id:saleId});
  if(claimError)return NextResponse.json({error:'Could not claim order notification'},{status:503});
  const sale=Array.isArray(claimed)?claimed[0]:claimed;
  if(!sale)return NextResponse.json({ok:true,alreadySent:true});
  webpush.setVapidDetails(process.env.VAPID_SUBJECT||'mailto:admin@example.com',process.env.VAPID_PUBLIC_KEY,process.env.VAPID_PRIVATE_KEY);
  const pendingUpi=sale.payment_method==='upi'&&sale.payment_status==='pending';
  const payload=JSON.stringify({
    title:pendingUpi?'UPI PAYMENT — VERIFY RECEIPT':'New sale recorded',
    body:`#${sale.order_number} · ${sale.quantity} ${sale.product_name}${sale.quantity===1?'':'s'} | ₹${sale.final_amount.toLocaleString('en-IN')} | ${sale.payment_method.toUpperCase()}${pendingUpi?' · Tap to verify receipt':''}`,
    url:pendingUpi?`/?pendingUpi=${sale.id}`:'/', saleId:sale.id, tag:`sale-${sale.order_number}`,
    actions:pendingUpi?[{action:'open-sale',title:'OPEN SALE'}]:[]
  });
  await Promise.all((subs||[]).map(async row=>{try{await webpush.sendNotification(row.subscription,payload)}catch(e:any){if(e.statusCode===404||e.statusCode===410)await admin.from('push_subscriptions').delete().eq('id',row.id)}}));
  return NextResponse.json({ok:true});
}

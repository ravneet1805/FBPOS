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
  const {data:sale}=await admin.from('sales').select('*').eq('id',saleId).single();
  if(!sale)return NextResponse.json({error:'Sale not found'},{status:404});
  webpush.setVapidDetails(process.env.VAPID_SUBJECT||'mailto:admin@example.com',process.env.VAPID_PUBLIC_KEY,process.env.VAPID_PRIVATE_KEY);
  const {data:subs}=await admin.from('push_subscriptions').select('id,subscription');
  const payload=JSON.stringify({title:'New sale recorded',body:`${sale.quantity} ${sale.product_name}${sale.quantity===1?'':'s'} | ₹${sale.final_amount.toLocaleString('en-IN')} | ${sale.payment_method.toUpperCase()}`});
  await Promise.all((subs||[]).map(async row=>{try{await webpush.sendNotification(row.subscription,payload)}catch(e:any){if(e.statusCode===404||e.statusCode===410)await admin.from('push_subscriptions').delete().eq('id',row.id)}}));
  return NextResponse.json({ok:true});
}

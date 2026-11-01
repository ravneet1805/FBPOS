import { NextRequest, NextResponse } from 'next/server';
import webpush from 'web-push';
import { admin } from '@/lib/admin';

export async function POST(req:NextRequest){
  const token=req.headers.get('authorization')?.replace(/^Bearer\s+/i,'');
  if(!token)return NextResponse.json({error:'Unauthorized'},{status:401});
  const {data:{user},error:authError}=await admin.auth.getUser(token);
  if(authError||!user)return NextResponse.json({error:'Unauthorized'},{status:401});
  if(!process.env.VAPID_PUBLIC_KEY||!process.env.VAPID_PRIVATE_KEY)return NextResponse.json({error:'Push is not configured'},{status:503});

  const {data:subs,error:subscriptionError}=await admin.from('push_subscriptions').select('id,subscription');
  if(subscriptionError)return NextResponse.json({error:subscriptionError.message},{status:503});
  if(!subs?.length)return NextResponse.json({sent:0});
  const {data:sales,error}=await admin.rpc('claim_due_upi_reminders');
  if(error)return NextResponse.json({error:error.message},{status:503});
  if(!sales?.length)return NextResponse.json({sent:0});
  webpush.setVapidDetails(process.env.VAPID_SUBJECT||'mailto:admin@example.com',process.env.VAPID_PUBLIC_KEY,process.env.VAPID_PRIVATE_KEY);
  let sent=0;
  await Promise.all(sales.map(async (sale:any)=>{
    const payload=JSON.stringify({
      title:'UPI PAYMENT — ACTION REQUIRED',
      body:`₹${sale.final_amount.toLocaleString('en-IN')} payment awaiting verification. Sale #${sale.id}.`,
      url:`/?pendingUpi=${sale.id}`,saleId:sale.id,tag:`upi-pending-${sale.id}`,
      actions:[{action:'review-upi',title:'VERIFY PAYMENT'}],reminder:true
    });
    await Promise.all((subs||[]).map(async row=>{
      try{await webpush.sendNotification(row.subscription,payload);sent++}
      catch(e:any){if(e.statusCode===404||e.statusCode===410)await admin.from('push_subscriptions').delete().eq('id',row.id)}
    }));
  }));
  return NextResponse.json({sent});
}

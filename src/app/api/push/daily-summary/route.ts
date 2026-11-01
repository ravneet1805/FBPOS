import { NextRequest, NextResponse } from 'next/server';
import webpush from 'web-push';
import { admin } from '@/lib/admin';

function istParts(date=new Date()){return new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Kolkata',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'}).formatToParts(date).reduce((o:any,p)=>({...o,[p.type]:p.value}),{})}
export async function GET(req:NextRequest){
  if(!process.env.CRON_SECRET||req.headers.get('authorization')!==`Bearer ${process.env.CRON_SECRET}`)return NextResponse.json({error:'Unauthorized'},{status:401});
  if(!process.env.VAPID_PUBLIC_KEY||!process.env.VAPID_PRIVATE_KEY)return NextResponse.json({error:'Push is not configured'},{status:503});
  const now=istParts();const today=`${now.year}-${now.month}-${now.day}`;
  const {data:setting}=await admin.from('daily_summary_settings').select('*').eq('id',1).maybeSingle();
  const time=(setting?.summary_time||'21:00').slice(0,5);if(`${now.hour}:${now.minute}`<time||setting?.last_sent_date===today)return NextResponse.json({sent:false});
  const start=new Date(`${today}T00:00:00+05:30`).toISOString(),end=new Date(`${today}T00:00:00+05:30`).getTime()+86400000;
  const {data:sales,error}=await admin.from('sales').select('final_amount,gross_amount,discount_amount,quantity,payment_method').eq('status','complete').gte('created_at',start).lt('created_at',new Date(end).toISOString());
  if(error)return NextResponse.json({error:error.message},{status:500});
  const stats=(sales||[]).reduce<{net:number;items:number;cash:number;upi:number}>((a,s)=>{a.net+=s.final_amount;a.items+=s.quantity;a[s.payment_method as 'cash'|'upi']+=s.final_amount;return a},{net:0,items:0,cash:0,upi:0});
  webpush.setVapidDetails(process.env.VAPID_SUBJECT||'mailto:admin@example.com',process.env.VAPID_PUBLIC_KEY,process.env.VAPID_PRIVATE_KEY);
  const {data:subs}=await admin.from('push_subscriptions').select('id,subscription');
  await Promise.all((subs||[]).map(async row=>{try{await webpush.sendNotification(row.subscription,JSON.stringify({title:'Today’s stall summary',body:`Today's sales: ₹${stats.net.toLocaleString('en-IN')} | ${stats.items} items sold | Cash: ₹${stats.cash.toLocaleString('en-IN')} | UPI: ₹${stats.upi.toLocaleString('en-IN')}`}))}catch(e:any){if(e.statusCode===404||e.statusCode===410)await admin.from('push_subscriptions').delete().eq('id',row.id)}}));
  await admin.from('daily_summary_settings').upsert({id:1,summary_time:time,last_sent_date:today});
  return NextResponse.json({sent:true,recipients:subs?.length||0});
}

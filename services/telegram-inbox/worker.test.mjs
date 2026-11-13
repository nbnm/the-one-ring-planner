import test from 'node:test';
import assert from 'node:assert/strict';
import {DatabaseSync} from 'node:sqlite';
import {readFileSync} from 'node:fs';
import worker, {publishGroup,hash} from './worker.mjs';

function fixture() {
  const sqlite=new DatabaseSync(':memory:'); sqlite.exec(readFileSync(new URL('./schema.sql',import.meta.url),'utf8'));
  const DB={prepare(sql) { let parameters=[]; return {bind(...values){parameters=values;return this;},async first(){return sqlite.prepare(sql).get(...parameters)||null;},async all(){return {results:sqlite.prepare(sql).all(...parameters)};},async run(){return sqlite.prepare(sql).run(...parameters);}};}};
  const objects=new Map(), sent=[], queued=[]; let clock=1794484800000, messageID=900;
  const env={DB,BOT_TOKEN:'synthetic-bot-token',WEBHOOK_SECRET:'synthetic-webhook-secret',PAIR_CODE:'synthetic-pair-code',CLIENT_TOKEN:'synthetic-client-token',MAX_PENDING_CAPTURES:'1000',TEST_NOW:()=>clock,
    ASSETS:{async put(key,bytes){objects.set(key,new Uint8Array(bytes));},async get(key){const value=objects.get(key);return value?{body:value}:null;}},
    QUEUE:{async send(body){queued.push(body);}},
    TEST_FETCH:async(url,options)=>{
      if (url.includes('/getFile')) return Response.json({ok:true,result:{file_path:'photos/image.jpg'}});
      if (url.includes('/file/')) return new Response(new Uint8Array([1,2,3,4]));
      if (url.includes('/sendMessage')) {sent.push(JSON.parse(options.body));return Response.json({ok:true,result:{message_id:messageID++}});}
      throw new Error('No real network is allowed');
    }};
  const request=message=>new Request('https://inbox.example/telegram',{method:'POST',headers:{'X-Telegram-Bot-Api-Secret-Token':env.WEBHOOK_SECRET},body:JSON.stringify({update_id:Math.random(),message})});
  const message=(id,text,extra={})=>({message_id:id,from:{id:123},chat:{id:123,type:'private'},date:Math.floor(clock/1000),text,...extra});
  const api=(path,options={})=>worker.fetch(new Request('https://inbox.example'+path,{...options,headers:{Authorization:'Bearer '+env.CLIENT_TOKEN,'content-type':'application/json',...options.headers}}),env);
  return {env,sqlite,objects,sent,queued,request,message,api,advance(ms=5000){clock+=ms;},async pair(){assert.equal((await worker.fetch(request(message(1,'/pair '+env.PAIR_CODE)),env)).status,200);}};
}
test('Webhook and single-owner pairing reject unrelated senders',async()=>{
  const f=fixture();
  assert.equal((await worker.fetch(new Request('https://inbox.example/telegram',{method:'POST',body:'{}'}),f.env)).status,403);
  await f.pair();
  await worker.fetch(f.request(f.message(2,'unrelated',{from:{id:456},chat:{id:456,type:'private'}})),f.env);
  assert.equal(f.sqlite.prepare('SELECT COUNT(*) count FROM messages').get().count,0);
  assert.equal((await worker.fetch(new Request('https://inbox.example/v1/captures'),f.env)).status,401);
  for (const token of [undefined,'']) {
    f.env.CLIENT_TOKEN=token;
    assert.equal((await f.api('/v1/captures')).status,401);
  }
});
test('Attachment and message bytes are durable before acknowledgement; retries deduplicate',async()=>{
  const f=fixture();await f.pair();
  const photo=f.message(3,undefined,{caption:'A reference',photo:[{file_id:'synthetic-file',file_size:4}]});
  const originalPut=f.env.ASSETS.put;f.env.ASSETS.put=async()=>{throw new Error('R2 unavailable');};
  assert.equal((await worker.fetch(f.request(photo),f.env)).status,503);
  assert.equal(f.sqlite.prepare('SELECT COUNT(*) count FROM messages').get().count,0);
  f.env.ASSETS.put=originalPut;
  assert.equal((await worker.fetch(f.request(photo),f.env)).status,200);
  assert.equal(f.objects.size,1);
  assert.equal((await worker.fetch(f.request(photo),f.env)).status,200);
  assert.equal(f.sqlite.prepare('SELECT COUNT(*) count FROM messages').get().count,1);
  f.advance();for(const message of f.queued)await publishGroup(f.env,message.groupKey);
  assert.equal(f.sqlite.prepare('SELECT COUNT(*) count FROM captures').get().count,1);
  assert.equal(f.sent.filter(x=>x.text.startsWith('Saved')).length,1);
});
test('Albums settle into one durable capture and return the stored attachment bytes',async()=>{
  const f=fixture();await f.pair();
  for(const id of [4,5])await worker.fetch(f.request(f.message(id,undefined,{caption:'Caption '+id,media_group_id:'album-one',photo:[{file_id:'file-'+id,file_size:4}]})),f.env);
  let ack=false,retry=false;
  await worker.queue({messages:[{body:f.queued[0],ack(){ack=true;},retry(){retry=true;}}]},f.env);
  assert.equal(ack,false);assert.equal(retry,true);
  f.advance();await publishGroup(f.env,f.queued[0].groupKey);
  const captures=await (await f.api('/v1/captures')).json();assert.equal(captures.length,1);assert.equal(captures[0].items.length,2);
  const capture=captures[0],asset=capture.items[0].files[0];
  const bytes=await (await f.api(`/v1/captures/${capture.id}/assets/${asset.hash}`)).arrayBuffer();assert.equal(await hash(bytes),asset.hash);
});
test('Mac receipts are idempotent and conflicting acknowledgements are preserved',async()=>{
  const f=fixture();await f.pair();await worker.fetch(f.request(f.message(6,'Exact\n```source```')),f.env);f.advance();await publishGroup(f.env,f.queued[0].groupKey);
  const [capture]=await (await f.api('/v1/captures')).json();
  const noteID='11111111-1111-4111-8111-111111111111';
  const ack=()=>f.api(`/v1/captures/${capture.id}/ack`,{method:'POST',body:JSON.stringify({captureID:capture.id,noteID})});
  assert.equal((await ack()).status,200);assert.equal((await ack()).status,200);
  assert.equal((await (await f.api('/v1/captures')).json()).length,0);
  assert.equal((await f.api(`/v1/captures/${capture.id}/ack`,{method:'POST',body:JSON.stringify({captureID:capture.id,noteID:'22222222-2222-4222-8222-222222222222'})})).status,409);
  await worker.fetch(f.request(f.message(60,'Concurrent receipt')),f.env);f.advance();await publishGroup(f.env,f.queued.at(-1).groupKey);
  const [other]=await (await f.api('/v1/captures')).json();
  const statuses=await Promise.all([noteID,'33333333-3333-4333-8333-333333333333'].map(async id=>(await f.api(`/v1/captures/${other.id}/ack`,{method:'POST',body:JSON.stringify({captureID:other.id,noteID:id})})).status));
  assert.deepEqual(statuses.sort(),[200,409]);
});
test('Replies to save acknowledgements append to the same Library thread',async()=>{
  const f=fixture();await f.pair();await worker.fetch(f.request(f.message(7,'First reference')),f.env);f.advance();await publishGroup(f.env,f.queued[0].groupKey);
  const first=await (await f.api('/v1/captures')).json();
  const notification=f.sqlite.prepare('SELECT * FROM notified').get();
  await worker.fetch(f.request(f.message(8,'A comment',{reply_to_message:{message_id:Number(notification.message_id)}})),f.env);f.advance();await publishGroup(f.env,f.queued.at(-1).groupKey);
  const all=await (await f.api('/v1/captures')).json();assert.equal(all.length,2);assert.equal(all[1].threadID,first[0].threadID);
});
test('Queue failures retain captures for retry without duplicate publication',async()=>{
  const f=fixture();await f.pair();await worker.fetch(f.request(f.message(9,'A queued reference')),f.env);f.advance();
  const originalFetch=f.env.TEST_FETCH;f.env.TEST_FETCH=async()=>new Response('',{status:503});let retried=false;
  await worker.queue({messages:[{body:f.queued[0],ack(){assert.fail('Must not ack failed delivery');},retry(){retried=true;}}]},f.env);
  assert.equal(retried,true);assert.equal(f.sqlite.prepare('SELECT COUNT(*) count FROM captures').get().count,1);
  f.env.TEST_FETCH=originalFetch;await publishGroup(f.env,f.queued[0].groupKey);
  assert.equal(f.sqlite.prepare('SELECT COUNT(*) count FROM captures').get().count,1);
});
test('Queue outage after durable write retries without losing the captured message',async()=>{
  const f=fixture();await f.pair();const send=f.env.QUEUE.send;f.env.QUEUE.send=async()=>{throw new Error('Queue outage');};
  assert.equal((await worker.fetch(f.request(f.message(10,'Durable before queue')),f.env)).status,503);
  assert.equal(f.sqlite.prepare('SELECT COUNT(*) count FROM messages').get().count,1);
  f.env.QUEUE.send=send;assert.equal((await worker.fetch(f.request(f.message(10,'Durable before queue')),f.env)).status,200);
  f.advance();await publishGroup(f.env,f.queued[0].groupKey);assert.equal((await (await f.api('/v1/captures')).json()).length,1);
});
test('Telegram photos without optional file_size still use bounded actual bytes',async()=>{
  const f=fixture();await f.pair();
  assert.equal((await worker.fetch(f.request(f.message(11,undefined,{caption:'Optional size',photo:[{file_id:'file-no-size'}]})),f.env)).status,200);
  f.advance();await publishGroup(f.env,f.queued[0].groupKey);
  const [capture]=await (await f.api('/v1/captures')).json();assert.equal(capture.items[0].files[0].byteCount,4);
});
test('Pending quota and asset scope fail closed without acknowledging data',async()=>{
  const f=fixture();await f.pair();await worker.fetch(f.request(f.message(12,'Pending one')),f.env);f.advance();await publishGroup(f.env,f.queued[0].groupKey);
  f.env.MAX_PENDING_CAPTURES='1';
  assert.equal((await worker.fetch(f.request(f.message(13,'Must retry later')),f.env)).status,503);
  const [capture]=await (await f.api('/v1/captures')).json();
  const absent=await hash('not-part-of-this-note');
  assert.equal((await f.api(`/v1/captures/${capture.id}/assets/${absent}`)).status,404);
  assert.equal(f.sqlite.prepare('SELECT COUNT(*) count FROM captures WHERE ack_at IS NULL').get().count,1);
});

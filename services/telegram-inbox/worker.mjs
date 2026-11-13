/* Private, single-owner Library capture. No Git or LiteLLM credentials belong here. */
const MAX_FILE = 20 * 1024 * 1024;
const MAX_GROUP = 30;
const encoder = new TextEncoder();
const json = (value, status = 200) => new Response(JSON.stringify(value), {status, headers:{'content-type':'application/json','cache-control':'no-store'}});
const now = env => env.TEST_NOW ? env.TEST_NOW() : Date.now();
export async function hash(value) {
  const bytes = typeof value === 'string' ? encoder.encode(value) : value;
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');
}
async function equal(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || !b) return false;
  const x = await hash(a), y = await hash(b); let result=0;
  for (let i=0;i<x.length;i++) result |= x.charCodeAt(i)^y.charCodeAt(i);
  return result===0;
}
async function telegram(env, method, payload) {
  const response = await (env.TEST_FETCH || fetch)(`https://api.telegram.org/bot${env.BOT_TOKEN}/${method}`, {method:'POST', headers:{'content-type':'application/json'}, body:JSON.stringify(payload)});
  if (!response.ok) throw new Error('Telegram API request failed');
  const body = await response.json(); if (!body.ok) throw new Error('Telegram API rejected the request'); return body.result;
}
async function fileBytes(env, file) {
  const info = await telegram(env,'getFile',{file_id:file.file_id});
  const declared=file.file_size ?? info.file_size;
  if (declared!==undefined && (!Number.isSafeInteger(declared) || declared<=0 || declared>MAX_FILE)) throw new Error('Unsupported file size');
  if (typeof info.file_path !== 'string' || info.file_path.includes('..') || !/^[a-zA-Z0-9_./-]+$/.test(info.file_path)) throw new Error('Invalid Telegram file path');
  const response = await (env.TEST_FETCH || fetch)(`https://api.telegram.org/file/bot${env.BOT_TOKEN}/${info.file_path}`);
  if (!response.ok || Number(response.headers.get('content-length')||0)>MAX_FILE) throw new Error('File download failed');
  const bytes=await response.arrayBuffer(); if ((declared!==undefined && bytes.byteLength!==declared) || bytes.byteLength===0 || bytes.byteLength>MAX_FILE) throw new Error('Incomplete file download');
  return bytes;
}
async function receive(request, env) {
  if (!await equal(request.headers.get('X-Telegram-Bot-Api-Secret-Token'),env.WEBHOOK_SECRET)) return json({error:'Unauthorized'},403);
  const raw=await request.text(); if (raw.length>256*1024) return json({error:'Too large'},413);
  let update; try { update=JSON.parse(raw); } catch { return json({error:'Invalid JSON'},400); }
  const message=update.message || update.edited_message;
  if (!message || message.chat?.type!=='private' || !message.from?.id || !message.chat?.id) return json({ignored:true});
  const user=String(message.from.id), chat=String(message.chat.id), text=message.text ?? message.caption ?? '';
  if (typeof text!=='string' || text.length>65536) return json({error:'Unsupported text'},400);
  const owner=await env.DB.prepare('SELECT * FROM owner WHERE singleton=1').first();
  if (!owner) {
    if (!text.startsWith('/pair ') || !await equal(text.slice(6).trim(),env.PAIR_CODE)) return json({ignored:true});
    // The UNIQUE singleton makes competing pairing attempts atomic; a retry can only confirm the winner.
    await env.DB.prepare('INSERT OR IGNORE INTO owner(singleton,user_id,chat_id) VALUES(1,?,?)').bind(user,chat).run();
    const paired=await env.DB.prepare('SELECT * FROM owner WHERE singleton=1').first();
    if (paired.user_id!==user || paired.chat_id!==chat) return json({ignored:true});
    await telegram(env,'sendMessage',{chat_id:chat,text:'Paired. Send text, photos, albums or Markdown files to your private Library inbox.'});
    return json({paired:true});
  }
  if (owner.user_id!==user || owner.chat_id!==chat) return json({ignored:true});
  if (text==='/start' || text.startsWith('/pair ')) return json({paired:true});
  if (!Number.isSafeInteger(message.message_id)) return json({error:'Invalid message'},400);
  const sourceID=`tg:${chat}:${message.message_id}:${message.edit_date||0}`;
  const groupKey=`${chat}:${message.media_group_id ? 'album:'+message.media_group_id : 'message:'+message.message_id}`;
  const prior=await env.DB.prepare('SELECT payload FROM messages WHERE id=?').bind(sourceID).first();
  if (prior) { await env.QUEUE.send({groupKey},{delaySeconds:5}); return json({stored:true,duplicate:true}); }
  const pending=await env.DB.prepare('SELECT COUNT(*) AS count FROM captures WHERE ack_at IS NULL').first();
  if (pending.count>=Number(env.MAX_PENDING_CAPTURES||1000)) return json({error:'Inbox full; import pending notes before retrying'},503);
  let threadID=await hash(groupKey);
  if (message.reply_to_message?.message_id) {
    const parent=await env.DB.prepare('SELECT thread_id FROM notified WHERE chat_id=? AND message_id=?').bind(chat,String(message.reply_to_message.message_id)).first();
    if (parent) threadID=parent.thread_id;
  }
  const attachments=[];
  let file, name, ext;
  if (Array.isArray(message.photo) && message.photo.length) { file=message.photo.at(-1); name=`photo-${message.message_id}.jpg`; ext='jpg'; }
  else if (message.document) {
    file=message.document; name=String(file.file_name||'reference.txt').slice(0,512); ext=name.split('.').at(-1).toLowerCase();
    if (!['png','jpg','jpeg','heic','md','markdown','txt'].includes(ext)) return json({error:'Use PNG, JPEG, HEIC, Markdown or UTF-8 text'},400);
  } else if (!text) return json({ignored:true});
  if (file) {
    const bytes=await fileBytes(env,file), digest=await hash(bytes);
    // R2 completion precedes the D1 message and webhook acknowledgement.
    await env.ASSETS.put(digest,bytes,{httpMetadata:{contentType:'application/octet-stream'}});
    attachments.push({hash:digest,byteCount:bytes.byteLength,name,fileExtension:ext});
  }
  const payload={id:sourceID,text,capturedAt:new Date((message.date||Math.floor(now(env)/1000))*1000).toISOString().replace('.000Z','Z'),files:attachments};
  await env.DB.prepare('INSERT OR IGNORE INTO messages(id,group_key,thread_id,chat_id,payload,updated_at) VALUES(?,?,?,?,?,?)').bind(sourceID,groupKey,threadID,chat,JSON.stringify(payload),now(env)).run();
  await env.QUEUE.send({groupKey},{delaySeconds:5});
  return json({stored:true});
}
export async function publishGroup(env, groupKey) {
  const result=await env.DB.prepare('SELECT * FROM messages WHERE group_key=? ORDER BY id').bind(groupKey).all();
  const rows=result.results||[]; if (!rows.length) return;
  if (rows.length>MAX_GROUP) throw new Error('Capture group exceeds 30 messages; manual recovery required');
  if (now(env)-Math.max(...rows.map(row=>row.updated_at))<2000) throw new Error('Album still settling');
  const items=rows.map(row=>JSON.parse(row.payload));
  const id=await hash(JSON.stringify({threadID:rows[0].thread_id,items}));
  const capture={id,threadID:rows[0].thread_id,items};
  await env.DB.prepare('INSERT OR IGNORE INTO captures(id,thread_id,payload,created_at) VALUES(?,?,?,?)').bind(id,capture.threadID,JSON.stringify(capture),now(env)).run();
  const notified=await env.DB.prepare('SELECT capture_id FROM notified WHERE capture_id=?').bind(id).first();
  if (!notified) {
    const acknowledgement=await telegram(env,'sendMessage',{chat_id:rows[0].chat_id,text:'Saved to Library inbox. It will import when your Mac is online. Reply here to add material to this note.'});
    await env.DB.prepare('INSERT OR IGNORE INTO notified(capture_id,chat_id,message_id,thread_id) VALUES(?,?,?,?)').bind(id,rows[0].chat_id,String(acknowledgement.message_id),capture.threadID).run();
  }
}
async function api(request,env,path) {
  if (!env.CLIENT_TOKEN || !await equal(request.headers.get('Authorization'),`Bearer ${env.CLIENT_TOKEN}`)) return json({error:'Unauthorized'},401);
  if (path==='/v1/captures' && request.method==='GET') {
    const result=await env.DB.prepare('SELECT payload FROM captures WHERE ack_at IS NULL ORDER BY created_at LIMIT 20').all();
    return json((result.results||[]).map(row=>JSON.parse(row.payload)));
  }
  let match=path.match(/^\/v1\/captures\/([a-f0-9]{64})\/assets\/([a-f0-9]{64})$/);
  if (match && request.method==='GET') {
    const row=await env.DB.prepare('SELECT payload FROM captures WHERE id=?').bind(match[1]).first();
    if (!row || !JSON.parse(row.payload).items.some(item=>item.files.some(file=>file.hash===match[2]))) return json({error:'Not found'},404);
    const object=await env.ASSETS.get(match[2]); if (!object) return json({error:'Bytes unavailable; capture retained'},503);
    return new Response(object.body,{headers:{'content-type':'application/octet-stream','cache-control':'no-store'}});
  }
  match=path.match(/^\/v1\/captures\/([a-f0-9]{64})\/ack$/);
  if (match && request.method==='POST') {
    const text=await request.text(); if (text.length>1024) return json({error:'Too large'},413);
    let body; try {body=JSON.parse(text);} catch {return json({error:'Invalid JSON'},400);}
    if (body.captureID!==match[1] || !/^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$/.test(body.noteID||'')) return json({error:'Invalid receipt'},400);
    const row=await env.DB.prepare('SELECT ack_note_id FROM captures WHERE id=?').bind(match[1]).first();
    if (!row) return json({error:'Not found'},404);
    if (row.ack_note_id && row.ack_note_id!==body.noteID) return json({error:'Receipt conflict; preserve both versions'},409);
    await env.DB.prepare('UPDATE captures SET ack_note_id=?,ack_at=? WHERE id=? AND (ack_note_id IS NULL OR ack_note_id=?)').bind(body.noteID,now(env),match[1],body.noteID).run();
    const saved=await env.DB.prepare('SELECT ack_note_id FROM captures WHERE id=?').bind(match[1]).first();
    if (saved?.ack_note_id!==body.noteID) return json({error:'Receipt conflict; preserve both versions'},409);
    return json({acknowledged:true});
  }
  return json({error:'Not found'},404);
}
export default {
  async fetch(request,env) {
    try {
      const path=new URL(request.url).pathname;
      if (path==='/telegram' && request.method==='POST') return await receive(request,env);
      if (path.startsWith('/v1/')) return await api(request,env,path);
      return json({service:'The One Ring Planner private Library inbox'});
    } catch { return json({error:'Capture not acknowledged. Durable content is retained; retry or inspect the service.'},503); }
  },
  async queue(batch,env) {
    for (const message of batch.messages) {
      try { await publishGroup(env,message.body.groupKey); message.ack(); }
      catch { message.retry({delaySeconds:30}); }
    }
  }
};

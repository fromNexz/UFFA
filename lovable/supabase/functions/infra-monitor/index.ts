// Novo backend v2. Deploy necessário; não representa rotas já publicadas pelo Lovable.
import {createClient} from 'npm:@supabase/supabase-js@2.118.0';
import {HttpError,uuid,text,object,intervals,command,ports,stamp,observation,sha256,randomToken,deriveToken,equalDigest} from './validation.ts';
const env=(k:string)=>Deno.env.get(k)??'';
const db=createClient(env('SUPABASE_URL'),env('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false}});
const publicColumns='id,legacy_host_id,hostname,store_name,intervals,last_seen_at,last_metrics_at,last_ips_at,last_processes_at,agent_version,agent_health,catalog,created_at';
function checked<T>(r:{data:T,error:any}):T {if(r.error){const status=['23505','P0001'].includes(r.error.code)?409:['23503','23514','22P02'].includes(r.error.code)?400:500;throw new HttpError(status,r.error.code==='23505'?'Conflito: já existe cadastro ou comando ativo':'Operação de banco recusada');}return r.data;}
async function body(req:Request){const len=Number(req.headers.get('content-length')??0);if(len>1048576)throw new HttpError(413,'Payload excedido');if(!(req.headers.get('content-type')??'').includes('application/json'))throw new HttpError(415,'Use application/json');const reader=req.body?.getReader();if(!reader)throw new HttpError(400,'Corpo ausente');let size=0;const chunks:Uint8Array[]=[];while(true){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>1048576){await reader.cancel();throw new HttpError(413,'Payload excedido');}chunks.push(value);}const all=new Uint8Array(size);let offset=0;for(const c of chunks){all.set(c,offset);offset+=c.length;}try{return object(JSON.parse(new TextDecoder().decode(all)));}catch(e){if(e instanceof HttpError)throw e;throw new HttpError(400,'JSON inválido');}}
async function admin(req:Request){const auth=req.headers.get('authorization')??'';if(!auth.startsWith('Bearer '))throw new HttpError(401,'Sessão necessária');const user=await db.auth.getUser(auth.slice(7));if(user.error||!user.data.user)throw new HttpError(401,'Sessão inválida');const role=checked(await db.from('user_roles').select('role').eq('user_id',user.data.user.id).eq('role','admin').maybeSingle());if(!role)throw new HttpError(403,'Administrador necessário');return user.data.user.id;}
async function agent(req:Request){const rawId=req.headers.get('x-host-id'),token=req.headers.get('x-host-token')??'';if(!rawId)throw new HttpError(401,'Identidade necessária');const id=uuid(rawId);if(token.length<32||token.length>512)throw new HttpError(401,'Identidade inválida');const host=checked(await db.from('im_hosts').select('*').eq('id',id).maybeSingle());if(!host||!host.token_hash||!equalDigest(host.token_hash,await sha256(token)))throw new HttpError(401,'Identidade inválida');return host;}
async function audit(host:string,actor:string,event:string,details:unknown={}){checked(await db.from('im_audit').insert({host_id:host,actor_id:actor,event,details}));}
async function handle(req:Request,route:string):Promise<unknown>{
 if(route==='enroll'&&req.method==='POST'){
  const b=await body(req),code=text(b.code,64,64),requestId=uuid(b.request_id);if(!/^[0-9a-f]{64}$/.test(code))throw new HttpError(400,'Código inválido');
  const token=await deriveToken(env('IM_ENROLLMENT_SECRET'),code,requestId);
  const rows=checked(await db.rpc('im_enroll',{_code_hash:await sha256(code),_request_id:requestId,_token_hash:await sha256(token),_host_id:b.host_id?uuid(b.host_id):null}));
  if(!rows?.length)throw new HttpError(401,'Código expirado ou utilizado');
  return {schema_version:2,host_id:rows[0].id,token};
 }
 if(route.startsWith('admin/')){
  const actor=await admin(req);
  if(route==='admin/hosts'&&req.method==='GET'){return {hosts:checked(await db.from('im_hosts').select(publicColumns).order('store_name')),legacy_hosts:checked(await db.from('hosts').select('id,hostname').order('hostname'))};}
  if(route==='admin/hosts'&&req.method==='POST'){
   const b=await body(req),code=randomToken(),legacy=b.legacy_host_id?uuid(b.legacy_host_id):null;
   if(legacy){const existing=checked(await db.from('hosts').select('id').eq('id',legacy).maybeSingle());if(!existing)throw new HttpError(404,'Host antigo não encontrado');}
   const hash=b.existing_token_sha256?text(b.existing_token_sha256,64,64):null;if(hash&&!/^[0-9a-f]{64}$/.test(hash))throw new HttpError(400,'SHA256 inválido');if(hash&&!legacy)throw new HttpError(400,'Importação exige UUID antigo');
   const host=checked(await db.from('im_hosts').insert({...(legacy?{id:legacy}:{}),legacy_host_id:legacy,hostname:text(b.hostname,1,100),store_name:text(b.store_name,1,120),token_hash:hash,enrollment_hash:hash?null:await sha256(code),enrollment_expires_at:hash?null:new Date(Date.now()+30*60000).toISOString()}).select(publicColumns).single());
   if(!host)throw new HttpError(500,'Cadastro não confirmado');
   await audit(host.id,actor,'host_provisioned',{legacy_host_id:legacy,identity_preserved:!!hash});return {host,enrollment_code:hash?null:code};
  }
  if(route==='admin/enrollment'&&req.method==='POST'){
   const b=await body(req),id=uuid(b.host_id);if(b.confirm!==true)throw new HttpError(400,'Confirmação necessária');
   const h=checked(await db.from('im_hosts').select('token_hash').eq('id',id).maybeSingle());if(!h)throw new HttpError(404,'Host inexistente');if(h.token_hash)throw new HttpError(409,'Host já possui identidade. Rotação exige procedimento separado; atualização não troca token.');
   const code=randomToken();checked(await db.from('im_hosts').update({enrollment_hash:await sha256(code),enrollment_expires_at:new Date(Date.now()+30*60000).toISOString()}).eq('id',id));await audit(id,actor,'enrollment_reissued');return {enrollment_code:code};
  }
  if(route==='admin/config'&&req.method==='POST'){
   const b=await body(req),id=uuid(b.host_id),settings=intervals(b.intervals);const row=checked(await db.from('im_hosts').update({intervals:settings}).eq('id',id).select('id').maybeSingle());if(!row)throw new HttpError(404,'Host inexistente');await audit(id,actor,'intervals_changed',settings);return {ok:true};
  }
  if(route==='admin/ips'&&req.method==='POST'){
   const b=await body(req),id=uuid(b.host_id),ip=text(b.ip,1,64);if(ip.includes('/')||!/^[0-9a-fA-F:.]+$/.test(ip))throw new HttpError(400,'IP literal obrigatório');if(typeof b.enabled!=='boolean')throw new HttpError(400,'enabled inválido');if(b.interval_seconds!=null&&(!Number.isInteger(b.interval_seconds)||b.interval_seconds<60||b.interval_seconds>86400))throw new HttpError(400,'Intervalo de IP inválido');
   const count=await db.from('im_ip_monitors').select('id',{count:'exact',head:true}).eq('host_id',id);checked(count);if((count.count??0)>=128){const existing=checked(await db.from('im_ip_monitors').select('id').eq('host_id',id).eq('ip',ip).maybeSingle());if(!existing)throw new HttpError(409,'Limite de 128 IPs');}
   const data=checked(await db.from('im_ip_monitors').upsert({host_id:id,ip,tcp_ports:ports(b.tcp_ports),name:text(b.name??'',0,120),description:text(b.description??'',0,500),enabled:b.enabled,interval_seconds:b.interval_seconds??null},{onConflict:'host_id,ip'}).select().single());await audit(id,actor,'ip_configured',{ip});return {ip:data};
  }
  if(route==='admin/commands'&&req.method==='POST'){
   const c=command(await body(req));const id=checked(await db.rpc('im_queue',{_host_id:c.host_id,_target_id:c.target_id,_operation:c.operation,_actor_id:actor,_reason:c.reason}));return {command_id:id};
  }
  if(route==='admin/detail'&&req.method==='GET'){
   const id=uuid(new URL(req.url).searchParams.get('host_id'));
   const h=checked(await db.from('im_hosts').select(publicColumns).eq('id',id).maybeSingle());if(!h)throw new HttpError(404,'Host inexistente');
   const latest:Record<string,any>={};for(const kind of ['metrics','ips','processes'])latest[kind]=checked(await db.from('im_observations').select('id,collected_at,received_at,payload').eq('host_id',id).eq('kind',kind).order('collected_at',{ascending:false}).limit(1).maybeSingle());
   return {host:h,latest,ips:checked(await db.from('im_ip_monitors').select('*').eq('host_id',id)),commands:checked(await db.from('im_commands').select('*').eq('host_id',id).order('created_at',{ascending:false}).limit(30)),audit:checked(await db.from('im_audit').select('*').eq('host_id',id).order('created_at',{ascending:false}).limit(50))};
  }
  throw new HttpError(404,'Rota administrativa inexistente');
 }
 const host=await agent(req);
 if(route==='agent-pull-config'&&req.method==='GET'){
  return {schema_version:2,intervals:host.intervals,ips:(checked(await db.from('im_ip_monitors').select('ip,tcp_ports,name,description,interval_seconds').eq('host_id',host.id).eq('enabled',true))??[]).map((r:any)=>({...r,ip:r.ip.replace(/\/(32|128)$/,'')})),pending_commands:checked(await db.rpc('im_pull',{_host_id:host.id}))};
 }
 if(route==='agent-heartbeat'&&req.method==='POST'){
  const b=await body(req);if(b.schema_version!==2)throw new HttpError(406,'schema_version=2 obrigatório');stamp(b.at);
  if(!Array.isArray(b.catalog)||b.catalog.length>64)throw new HttpError(400,'Catálogo inválido');
  for(const t of b.catalog){if(!/^[a-zA-Z0-9_-]{1,64}$/.test(t.id)||!['service','process'].includes(t.kind)||!Array.isArray(t.allowed_operations)||t.allowed_operations.some((o:string)=>!['start','stop','restart','kill'].includes(o))||typeof t.allow_force!=='boolean')throw new HttpError(400,'Catálogo inválido');}
  for(const k of ['working_set_bytes','private_bytes'])if(!Number.isFinite(b[k])||b[k]<0)throw new HttpError(400,'Memória inválida');
  checked(await db.from('im_hosts').update({last_seen_at:new Date().toISOString(),agent_version:text(b.agent_version,1,32),catalog:b.catalog,agent_health:{working_set_bytes:b.working_set_bytes,private_bytes:b.private_bytes}}).eq('id',host.id));return {ok:true};
 }
 if((route==='ingest'||route==='agent-status')&&req.method==='POST'){
  const raw=await body(req),kind=route==='ingest'?'metrics':raw.kind;if(!['metrics','ips','processes'].includes(kind))throw new HttpError(400,'Tipo inválido');const b=observation(raw,kind);
  if(kind==='ips') {const known=(checked(await db.from('im_ip_monitors').select('ip').eq('host_id',host.id).eq('enabled',true))??[]).map((r:any)=>r.ip.replace(/\/(32|128)$/,''));for(const ip of b.ips)if(!known.includes(ip.ip))throw new HttpError(400,'IP não configurado para este host');}
  const ok=checked(await db.rpc('im_record',{_host_id:host.id,_id:b.observation_id,_kind:kind,_collected_at:kind==='metrics'?b.metrics.collected_at:b.checked_at,_payload:b}));if(!ok)throw new HttpError(409,'Observação duplicada divergente ou inválida');return {ok:true};
 }
 if(route==='agent-action-result'&&req.method==='POST'){
  const b=await body(req),id=uuid(b.command_id),result=text(b.result,2,5);if(!['ok','error'].includes(result))throw new HttpError(400,'Resultado inválido');const ok=checked(await db.rpc('im_complete',{_host_id:host.id,_id:id,_result:result,_message:text(b.message,0,2000)}));if(!ok)throw new HttpError(409,'Comando inexistente, de outro host ou resultado divergente');return {ok:true};
 }
 throw new HttpError(404,'Rota inexistente');
}
Deno.serve(async(req:Request)=>{
 const requestId=crypto.randomUUID();
 const origin=req.headers.get('origin'),allowed=env('ALLOWED_ORIGINS').split(',').map(x=>x.trim()).filter(Boolean);
 const headers:Record<string,string>={'Content-Type':'application/json','Cache-Control':'no-store','Vary':'Origin','Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info,x-host-id,x-host-token','Access-Control-Allow-Methods':'GET,POST,OPTIONS'};
 if(origin&&allowed.includes(origin))headers['Access-Control-Allow-Origin']=origin;
 try {
  if(origin&&!allowed.includes(origin))throw new HttpError(403,'Origem não permitida');
  if(req.method==='OPTIONS')return new Response(null,{status:204,headers});
  const path=new URL(req.url).pathname,marker='/infra-monitor/';const pos=path.indexOf(marker);const route=pos>=0?path.slice(pos+marker.length):'';
  const data=await handle(req,route);return new Response(JSON.stringify(data),{status:200,headers});
 }catch(e){const status=e instanceof HttpError?e.status:500;console.error(JSON.stringify({event:'request_failed',request_id:requestId,status}));return new Response(JSON.stringify({error:e instanceof HttpError?e.message:'Erro interno',request_id:requestId}),{status,headers});}
});

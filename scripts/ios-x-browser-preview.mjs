// Run through scripts/run-ios-x-preview.sh (supplies an absolute artifact path).
// Simulator-only visual test adapter; never connects to KKRemote Host.
const fs = await import('node:fs/promises');
const http = await import('node:http');
const crypto = await import('node:crypto');
const base = globalThis.kkremotePreviewDirectory;
if (typeof base !== 'string' || !base.startsWith('/')) throw Error('Use scripts/run-ios-x-preview.sh');
await fs.mkdir(base, {recursive:true});
try {
  const previous = JSON.parse(await fs.readFile(`${base}/bridge.json`,'utf8'));
  let alive = false;
  try { process.kill(previous.pid,0); alive = true; } catch(error) { if(error.code!=='ESRCH') throw error; }
  if(alive) throw Error('An X preview adapter is already running');
  await fs.rm(`${base}/bridge.json`,{force:true});
} catch(error) { if(error.code!=='ENOENT') throw error; }

const task = await taskSpace('KKRemote iPhone native redesign');
const page = task.page('p1');
// Select X's own mobile presentation; do not crop or rewrite its page contents.
await page.cdp('Emulation.setDeviceMetricsOverride',{width:402,height:778,deviceScaleFactor:3,mobile:true});
await page.cdp('Emulation.setUserAgentOverride',{userAgent:'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1',platform:'iPhone'});
await page.goto('https://x.com/explore');
await page.waitForSelector('input[placeholder="Search"]', {state:'visible'});
const token = crypto.randomUUID();
const committed = new Set();
let queue = Promise.resolve(), count = 0, size = {width:402,height:657};
async function searchBounds() {
  return page.evaluate(() => {
    const input = document.querySelector('input[placeholder="Search"]');
    if (!input) return null;
    const r = input.getBoundingClientRect();
    return {x:r.x,y:r.y,width:r.width,height:r.height,focused:document.activeElement===input,value:input.value};
  });
}
async function run(event) {
  let status = 'X · 本地浏览器预览';
  if (event.kind === 'reset') {
    // Each simulator test starts from the same isolated page, including after a failed run.
    await page.goto('https://x.com/explore');
    await page.waitForSelector('input[placeholder="Search"]', {state:'visible'});
    await page.evaluate(()=>window.scrollTo(0,0));
  } else if (event.kind === 'resize') {
    const width = Math.round(event.width), height = Math.round(event.height);
    if (![width,height].every(Number.isFinite) || width < 320 || width > 1600 || height < 160 || height > 2400) throw Error('Invalid size');
    size = {width,height};
    await page.cdp('Emulation.setDeviceMetricsOverride', {...size,deviceScaleFactor:3,mobile:true});
    await page.waitForFunction(({width,height}) => window.innerWidth===width && window.innerHeight===height,size,{timeout:5000});
  } else if (event.kind === 'scroll') {
    const dy = Math.max(-800,Math.min(800,Number(event.dy)||0));
    await page.mouse.move(size.width/2,size.height*0.65);
    await page.mouse.wheel(0,-dy);
  } else if (event.kind === 'tap') {
    const r = await searchBounds();
    if (r && event.x>=r.x && event.x<r.x+r.width && event.y>=r.y && event.y<r.y+r.height) {
      await page.click('input[placeholder="Search"]'); status = '已选中 X 搜索框';
    } else { status = '此测试仅开放滚动和搜索框输入'; }
  } else if (event.kind === 'text' || event.kind === 'replaceText') {
    if (typeof event.text !== 'string' || event.text.length>4000 || typeof event.id!=='string') throw Error('Invalid text');
    const r = await searchBounds();
    if (!r?.focused) throw Error('请先点击 X 搜索框');
    if (!committed.has(event.id)) {
      if (event.kind === 'replaceText') await page.fill('input[placeholder="Search"]',event.text);
      else await page.keyboard.insertText(event.text);
      committed.add(event.id); if (committed.size>128) committed.delete(committed.values().next().value);
    }
    status = '已填入 X 搜索框（未按回车）';
  } else if (event.kind === 'clear') {
    await page.fill('input[placeholder="Search"]',''); status = '已清空测试搜索文字';
  } else if (event.kind !== 'refresh') { throw Error('Unsupported preview action'); }
  // Wait for layout to settle after resize/input before pairing pixels and size.
  await page.evaluate(() => new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
  const actual = await page.evaluate(()=>({width:innerWidth,height:innerHeight,pixelRatio:devicePixelRatio,scrollY:scrollY}));
  const filename = `${base}/frame.png`;
  // The high-level screenshot helper normalizes to CSS pixels. Capture the
  // compositor pixels directly and declare the measured density, not a guess.
  const captured = await page.cdp('Page.captureScreenshot',{format:'png',fromSurface:true,captureBeyondViewport:false});
  const bytes = Buffer.from(captured.data,'base64');
  actual.pixelRatio = bytes.readUInt32BE(16) / actual.width;
  if (Math.abs(bytes.readUInt32BE(20) / actual.height - actual.pixelRatio)>0.001) throw Error('Screenshot geometry mismatch');
  await fs.writeFile(filename,bytes);
  const image = bytes.toString('base64');
  const search = await searchBounds();
  await fs.appendFile(`${base}/events.jsonl`,JSON.stringify({kind:event.kind,sequence:++count,width:actual.width,height:actual.height,scrollY:actual.scrollY,textLength:event.text?.length,at:new Date().toISOString()})+'\n');
  return {image,...actual,search,status,sequence:count};
}
const server = http.createServer((req,res)=>{
  if (req.headers.authorization!==`Bearer ${token}` || req.method!=='POST' || req.url!=='/event') {res.writeHead(403);res.end();return;}
  let bytes=0, body='';
  req.on('data', chunk=>{bytes+=chunk.length;if(bytes>16000){req.destroy();return;}body+=chunk;});
  req.on('end',()=>{
    queue=queue.then(async()=>{
      try {const value=await run(JSON.parse(body));res.writeHead(200,{'Content-Type':'application/json'});res.end(JSON.stringify(value));}
      catch(error){res.writeHead(400,{'Content-Type':'application/json'});res.end(JSON.stringify({error:String(error.message||error)}));}
    });
  });
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
await fs.writeFile(`${base}/bridge.json`,JSON.stringify({url:`http://127.0.0.1:${server.address().port}/event`,token,spaceId:task.spaceId,pid:process.pid}));
console.log(JSON.stringify({ready:true,spaceId:task.spaceId,port:server.address().port}));
let closing=false;
async function close(){
  if(closing)return;closing=true;
  server.close();await queue;
  await fs.rm(`${base}/bridge.json`,{force:true});
  // Only discard text in this task's isolated search box, never account drafts.
  try {await page.fill('input[placeholder="Search"]','');} catch {}
  await task.finish({keep:[]});
  process.exit(0);
}
process.on('SIGTERM',close);process.on('SIGINT',close);
// Development reload keeps this same browser TaskSpace; it does not finish it.
process.on('SIGUSR2',async()=>{
  if(closing)return;closing=true;server.close();await queue;
  await fs.rm(`${base}/bridge.json`,{force:true});process.exit(0);
});
await new Promise(()=>{});

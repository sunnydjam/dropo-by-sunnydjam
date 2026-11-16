const {test, before, after} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const {chromium} = require('playwright');

const assets = path.resolve(__dirname, '../../flutter_app/assets');
let server, browser, origin;
const idle = {connected:false, connecting:false, disconnecting:false, enabled:true,
  busy:false, canCancel:false, active:true, motion:true, error:false, message:'',
  source:'Dropo Free', mode:'blocked_only'};

before(async () => {
  server = http.createServer((req, res) => {
    const name = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    const file = path.resolve(assets, '.' + name);
    if (!file.startsWith(assets + path.sep)) {res.writeHead(403).end(); return;}
    try {
      const types = {'.html':'text/html; charset=utf-8', '.js':'text/javascript; charset=utf-8',
        '.css':'text/css; charset=utf-8', '.ttf':'font/ttf'};
      res.writeHead(200, {'content-type': types[path.extname(file)] || 'application/octet-stream'});
      res.end(fs.readFileSync(file));
    } catch {res.writeHead(404).end();}
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  origin = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({headless:true,
    ...(process.env.DROPO_TEST_BROWSER ? {executablePath:process.env.DROPO_TEST_BROWSER} : {}),
    args:['--enable-unsafe-swiftshader', '--use-angle=swiftshader']});
});
after(async () => {
  await browser?.close();
  if (server) await new Promise(resolve => server.close(resolve));
});

async function pageFor(t, {viewport={width:390,height:760}, fault=null}={}) {
  const context = await browser.newContext({viewport, deviceScaleFactor:1});
  t.after(() => context.close());
  await context.addInitScript(() => {
    window.sceneMessages=[];window.paintCount=0;
    window.DropoScene={postMessage:value=>window.sceneMessages.push(JSON.parse(value))};
    for (const type of [window.WebGLRenderingContext, window.WebGL2RenderingContext]) {
      if (!type) continue;
      const original=type.prototype.drawElements;
      type.prototype.drawElements=function(...args){window.paintCount++;return original.apply(this,args);};
    }
  });
  const page = await context.newPage(), errors=[], external=[];
  page.on('pageerror', e => errors.push(e.message));
  await page.route('**/*', async route => {
    const url=route.request().url();
    if (!url.startsWith(origin + '/')) {external.push(url);return route.abort();}
    if (fault && url.endsWith('/' + fault)) return route.abort('failed');
    return route.continue();
  });
  t.after(() => assert.deepEqual(external, [], 'scene must not access external services'));
  if (!fault) t.after(() => assert.deepEqual(errors, [], 'no runtime errors'));
  await page.goto(origin+'/android_home/index.html');
  if (!fault) {
    await page.waitForFunction(() => window.sceneMessages.some(x=>x.action==='ready'));
    await update(page, idle);
    assert.equal(await page.title(), 'Подключение Dropo');
  }
  return page;
}
const update=(page,state)=>page.evaluate(state=>window.DropoHome.update(state),state);
const state=page=>page.evaluate(()=>{
  const q=s=>document.querySelector(s), d=q('.dp-details');
  return {state:q('.dp-main').dataset.state, phase:q('.dp-main').dataset.phase,
    status:q('.dp-status-text').textContent, hidden:d.hidden, inert:d.inert,
    disabled:q('.dp-mode-all').disabled, retryDisabled:q('.dp-start').disabled,
    timer:q('.dp-session-time').textContent, messages:window.sceneMessages};
});

test('success exposes controls synchronously while artwork completes its flight', async t => {
  const page=await pageFor(t);
  await update(page,{connecting:true,enabled:false,canCancel:true,busy:true});
  await page.waitForTimeout(150);
  const immediate=await page.evaluate(()=>{
    window.DropoHome.update({connected:true,connecting:false,canCancel:false,busy:false,enabled:true});
    const d=document.querySelector('.dp-details');
    return {hidden:d.hidden,inert:d.inert,disabled:document.querySelector('.dp-mode-all').disabled,
      status:document.querySelector('.dp-status-text').textContent};
  });
  assert.deepEqual(immediate,{hidden:false,inert:false,disabled:false,status:'VPN подключён'});
  await page.locator('.dp-mode-all').click();
  assert.ok((await state(page)).messages.some(x=>x.action==='mode'&&x.value==='all_traffic'));
});

test('native busy gate remains authoritative even when the VPN is connected', async t => {
  const page=await pageFor(t);
  await update(page,{connected:true,enabled:false,busy:true});
  let current=await state(page);assert.equal(current.hidden,false);assert.equal(current.disabled,true);
  await update(page,{enabled:true,busy:false});
  assert.equal((await state(page)).disabled,false);
});

test('cancel and error retry send native commands without inventing success', async t => {
  const page=await pageFor(t);
  await update(page,{connecting:true,enabled:false,canCancel:true});
  await page.locator('.dp-cancel').click();
  assert.ok((await state(page)).messages.some(x=>x.action==='cancel'));
  await update(page,{...idle,error:true,message:'Не удалось подключиться'});
  assert.equal((await state(page)).state,'error');
  await page.locator('.dp-start').click();
  let current=await state(page);assert.equal(current.state,'error');
  assert.ok(current.messages.some(x=>x.action==='toggle'));
  await update(page,{connecting:true,enabled:false,canCancel:true});
  assert.equal((await state(page)).state,'connecting');
});

test('a nonfatal warning does not turn an active connection into an error', async t => {
  const page=await pageFor(t);
  await update(page,{connected:true,error:true,message:'Список источников пока не обновился'});
  assert.equal((await state(page)).state,'connected');
});

test('authoritative uptime corrects an already visible session timer', async t => {
  const page=await pageFor(t);
  await update(page,{connected:true,connectedAt:null});
  assert.equal((await state(page)).timer,'00:00');
  await page.evaluate(()=>window.DropoHome.update({connected:true,connectedAt:Date.now()-137000}));
  assert.match((await state(page)).timer,/^02:1[78]$/);
});

test('background pauses drawing but a native success still updates the controls', async t => {
  const page=await pageFor(t);
  await update(page,{active:false});
  const paints=await page.evaluate(()=>window.paintCount);
  await page.waitForTimeout(150);
  assert.equal(await page.evaluate(()=>window.paintCount),paints);
  await update(page,{connected:true});
  assert.equal((await state(page)).hidden,false);
  await update(page,{active:true});
  await page.waitForFunction(count=>window.paintCount>count,paints);
});

test('motion preference changes never replay a stale flight or error transition', async t => {
  const page=await pageFor(t);
  for (const [native,expected,phase] of [
    [{...idle,error:true},'error','error'],
    [{...idle,connecting:true},'connecting','orbit'],
    [{...idle},'idle','idle'],
  ]) {
    await update(page,{...native,motion:false});await update(page,{motion:true});
    const current=await state(page);assert.equal(current.state,expected);assert.equal(current.phase,phase);
  }
});

test('mascot resources remain the exact approved original green poses', async t => {
  const page=await pageFor(t);
  const data=await page.evaluate(()=>Object.fromEntries(['waiting','flying','puzzled'].map(k=>[k,window.DropoArt[k]])));
  for (const [kind,url] of Object.entries(data)) {
    assert.deepEqual(Buffer.from(url.split(',')[1],'base64'),fs.readFileSync(path.join(assets,'mascot',`droppo_${kind}.png`)));
  }
});

for (const file of ['scene.js','art.js','scene.css','vendor/three-0.160.1.min.js']) {
  test(`missing ${file} asks Flutter to show native fallback controls`, async t => {
    const page=await pageFor(t,{fault:file});
    await page.waitForFunction(()=>window.sceneMessages.some(x=>x.action==='failed'));
  });
}

test('a runtime script failure asks for fallback even after successful startup', async t => {
  const page=await pageFor(t);
  await page.evaluate(()=>window.dispatchEvent(new ErrorEvent('error',{message:'synthetic renderer failure'})));
  assert.ok((await state(page)).messages.some(x=>x.action==='failed'));
});

for (const viewport of [{width:360,height:600},{width:320,height:600},{width:760,height:390}]) {
  test(`long error and connection controls remain readable at ${viewport.width}x${viewport.height}`, async t => {
    const page=await pageFor(t,{viewport});
    await update(page,{error:true,motion:false,message:'Не удалось подключиться к выбранному источнику. Проверьте соединение с интернетом и доступность сервера, затем попробуйте ещё раз. Если ошибка повторяется, выберите другой источник в меню.'});
    await page.waitForTimeout(80);
    const overlaps=await page.evaluate(()=>{
      const a=document.querySelector('.dp-hint span').getBoundingClientRect();
      const b=document.querySelector('.dp-message').getBoundingClientRect();
      return a.x<b.right&&a.right>b.x&&a.y<b.bottom&&a.bottom>b.y;
    });
    assert.equal(overlaps,false,'error text must not cover the retry caption');
    await update(page,{connected:true,error:false,message:''});
    const bounds=await page.evaluate(()=>{
      const doc=document.documentElement,b=document.querySelector('.dp-disconnect').getBoundingClientRect();
      return {width:doc.scrollWidth,viewport:innerWidth,bottom:b.bottom,height:doc.scrollHeight};
    });
    assert.ok(bounds.width<=bounds.viewport);assert.ok(bounds.bottom<=bounds.height);
  });
}

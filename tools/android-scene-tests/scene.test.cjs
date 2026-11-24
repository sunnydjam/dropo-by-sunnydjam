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

async function pageFor(t, {viewport={width:390,height:760}, fault=null, manualStartup=false}={}) {
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
  if (!fault && !manualStartup) {
    await update(page, idle);
    const revision = await preparedFrame(page);
    assert.equal(await reveal(page, revision), true);
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

const reveal = (page, revision) => page.evaluate(
  revision => window.DropoHome.reveal(revision, innerWidth * devicePixelRatio, innerHeight * devicePixelRatio),
  revision,
);

const preparedFrame = async (page, after) => {
  const result = await page.waitForFunction(after => {
    const ready = window.sceneMessages.filter(message => message.action === 'ready').pop();
    return ready && ready.value !== after && ready.value;
  }, after);
  return result.jsonValue();
};

test('startup waits for host state and two drawn frames, and ignores an outdated viewport', async t => {
  const page = await pageFor(t, {manualStartup: true});
  const main = page.locator('.dp-main');
  const power = page.locator('.dp-start');
  assert.equal(await main.getAttribute('data-startup'), 'loading');
  assert.equal(await main.isVisible(), false);
  assert.equal(await power.isDisabled(), true);
  assert.deepEqual((await state(page)).messages, []);

  await update(page, {...idle, active:false});
  await page.waitForTimeout(120);
  assert.deepEqual((await state(page)).messages, []);
  await update(page, {active:true, motion:false});
  const oldRevision = await preparedFrame(page);
  assert.ok(await page.evaluate(() => window.paintCount > 0));
  assert.equal(await main.getAttribute('aria-hidden'), 'true');
  assert.equal(await power.isDisabled(), true);
  await page.evaluate(() => document.querySelector('.dp-start').dispatchEvent(new MouseEvent('click')));
  assert.equal((await state(page)).messages.some(message => message.action === 'connect'), false);

  await page.setViewportSize({width:360, height:680});
  assert.equal(await reveal(page, oldRevision), false);
  const revision = await preparedFrame(page, oldRevision);
  assert.equal(await page.evaluate(
    revision => window.DropoHome.reveal(revision, 390, 760), revision,
  ), false, 'a frame from the old native surface cannot lift the cover');
  assert.equal(await reveal(page, revision), true);
  assert.equal(await main.getAttribute('data-startup'), 'visible');
  assert.equal(await main.getAttribute('aria-hidden'), null);
  assert.equal(await power.isEnabled(), true);
  const positions = await page.evaluate(() => {
    const bounds = document.querySelector('.dp-start').getBoundingClientRect();
    return [bounds.left + bounds.width / 2, innerWidth / 2];
  });
  assert.deepEqual(positions, [180, 180]);
});

test('offline service setup and verified connection controls are immediately actionable', async t => {
  const page = await pageFor(t);
  await page.locator('.dp-mode-service').click();
  assert.equal((await state(page)).messages.at(-1).action, 'mode');
  await page.locator('.dp-services').click();
  assert.equal((await state(page)).messages.at(-1).action, 'services');
  assert.equal(await page.locator('.dp-disconnect').isVisible(), false);
  await update(page, {connecting:true, enabled:false});
  assert.equal(await page.locator('.dp-mode-service').isVisible(), false);
  await update(page, {connecting:false, enabled:true, connected:true, responseMs:78});
  let current = await state(page);
  assert.equal(current.state, 'connected');
  current = await state(page);
  assert.equal(current.hidden, false);
  assert.equal(current.disabled, false);
  assert.equal(await page.locator('.dp-response').textContent(), '78 мс');
  await page.locator('.dp-mode-all').click();
  assert.equal((await state(page)).messages.at(-1).action, 'mode');
});

test('Earth starts a connection and only the Disconnect button stops it', async t => {
  const page = await pageFor(t);
  const earth = page.locator('.dp-earth-action');
  await update(page, {motion:false});
  const globe = await earth.boundingBox();
  await page.mouse.click(globe.x + globe.width * .2, globe.y + globe.height / 2);
  assert.equal((await state(page)).messages.at(-1).action, 'connect');

  await update(page, {connecting:true, canCancel:true, enabled:false});
  assert.equal(await earth.isHidden(), true);
  await earth.dispatchEvent('click');
  assert.equal((await state(page)).messages.at(-1).action, 'connect');

  const oldTop = await earth.evaluate(button => button.style.top);
  await update(page, {connected:true, connecting:false, canCancel:false, enabled:true});
  assert.equal(await earth.isHidden(), true);
  await page.waitForFunction(
    oldTop => document.querySelector('.dp-earth-action').style.top !== oldTop, oldTop,
  );
  const center = await earth.evaluate(button => {
    const scene = button.parentElement.getBoundingClientRect();
    return [scene.left + parseFloat(button.style.left) + parseFloat(button.style.width) / 2,
      scene.top + parseFloat(button.style.top) + parseFloat(button.style.height) / 2];
  });
  await page.mouse.click(...center);
  await earth.dispatchEvent('click');
  assert.equal((await state(page)).messages.at(-1).action, 'connect');
  await page.locator('.dp-disconnect').click();
  assert.equal((await state(page)).messages.at(-1).action, 'disconnect');
});

test('native busy gate remains authoritative even when the VPN is connected', async t => {
  const page=await pageFor(t);
  await update(page,{connected:true,enabled:false,busy:true,motion:false});
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
  assert.ok(current.messages.some(x=>x.action==='connect'));
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
  const data=await page.evaluate(()=>Object.fromEntries(['waiting','flying','puzzled','rising','pushOff','recovering'].map(k=>[k,window.DropoArt[k]])));
  for (const [kind,url] of Object.entries(data)) {
    assert.deepEqual(Buffer.from(url.split(',')[1],'base64'),fs.readFileSync(path.join(assets,'mascot',`droppo_${kind === 'pushOff' ? 'push_off' : kind}.png`)));
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
    const retry=await page.evaluate(()=>{
      const a=document.querySelector('.dp-hint span').getBoundingClientRect();
      const b=document.querySelector('.dp-message').getBoundingClientRect();
      const canvas=document.querySelector('.dp-hint canvas');
      const power=document.querySelector('.dp-start').getBoundingClientRect();
      const arrow=canvas.getBoundingClientRect();
      const tipX=90+39*Math.sin(Math.PI/6), tipY=39*Math.cos(Math.PI/6);
      const tip=canvas.getContext('2d').getImageData(Math.round(tipX*2),Math.round(tipY*2),1,1);
      return {
        overlaps:a.x<b.right&&a.right>b.x&&a.y<b.bottom&&a.bottom>b.y,
        tipVisible:tip.data[3]>0&&arrow.width>0&&arrow.height>0,
        tipDistance:Math.hypot(arrow.left+tipX-power.left-power.width/2,
                               arrow.top+tipY-power.top-power.height/2),
      };
    });
    assert.equal(retry.overlaps,false,'error text must not cover the retry caption');
    assert.ok(retry.tipVisible,'retry keeps the drawn arrow visible');
    assert.ok(Math.abs(retry.tipDistance-39)<2,'the retry arrow points to the power button border');
    await update(page,{connected:true,error:false,message:''});
    const bounds=await page.evaluate(()=>{
      const doc=document.documentElement,b=document.querySelector('.dp-disconnect').getBoundingClientRect();
      return {width:doc.scrollWidth,viewport:innerWidth,bottom:b.bottom,height:doc.scrollHeight};
    });
    assert.ok(bounds.width<=bounds.viewport);assert.ok(bounds.bottom<=bounds.height);
  });
}

test('embedded home leaves route settings to Flutter and keeps session controls visible', async t => {
  const page = await pageFor(t, {viewport:{width:360,height:450}});
  await update(page, {...idle, sharedRouteControls:true, connected:true, motion:false});
  assert.equal(await page.locator('.dp-mode-service').isVisible(), false);
  assert.equal(await page.locator('.dp-services').isVisible(), false);
  const box = await page.locator('.dp-disconnect').boundingBox();
  assert.ok(box && box.y >= 0 && box.y + box.height <= 450, 'Disconnect fits the compact hero');
});

test('embedded home announces landing once after the orbit on a fast connection', async t => {
  const page = await pageFor(t);
  const embedded = {...idle, sharedRouteControls:true};
  await update(page, embedded);
  assert.equal((await state(page)).hidden, true);

  await update(page, {...embedded, connecting:true});
  await update(page, {...embedded, connected:true});
  const takingOff = await state(page);
  assert.ok(['launch','orbit'].includes(takingOff.phase));
  assert.equal(takingOff.hidden, true);
  assert.equal(takingOff.messages.filter(message => message.action === 'landed').length, 0);

  await page.waitForFunction(() => window.sceneMessages.some(message => message.action === 'landed'));
  const landed = await state(page);
  assert.equal(landed.phase, 'connected');
  assert.equal(landed.hidden, false);
  await update(page, {...embedded, connected:true});
  assert.equal((await state(page)).messages.filter(message => message.action === 'landed').length, 1);

  await update(page, embedded);
  assert.equal((await state(page)).hidden, true);
});

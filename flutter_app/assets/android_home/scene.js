// Local presentation only: native Flutter/CoreBridge owns connection and control availability.
(() => {
  const root = document.getElementById('dropo-motion-preview');
  const $ = selector => root.querySelector(selector);
  const phone = $('.dp-phone'), main = $('.dp-main'), scene = $('.dp-scene');
  const power = $('.dp-start'), earthAction = $('.dp-earth-action'), hint = $('.dp-hint');
  const cancel = $('.dp-cancel'), details = $('.dp-details'), status = $('.dp-status-text');
  const service = $('.dp-mode-service'), all = $('.dp-mode-all'), timer = $('.dp-session-time');
  const spaceCanvas = $('.dp-space'), space = spaceCanvas.getContext('2d');
  const haloCanvas = $('.dp-globe'), halo = haloCanvas.getContext('2d'), canvas = $('.dp-front');
  const mq = matchMedia('(prefers-reduced-motion: reduce)');
  const settings = { motion: !mq.matches };
  const clamp = (x, a = 0, b = 1) => Math.max(a, Math.min(b, x));
  const mix = (a, b, p) => a + (b - a) * p;
  const smooth = x => { const p = clamp(x); return p * p * (3 - 2 * p); };
  const artInfo = {
    waiting: { crop: [.13716108, .04066986, .63955343, .90271132], aspect: 1.41147132 },
    flying: { crop: [.02472089, .14593301, .93859649, .73763955], aspect: .78589635 },
    puzzled: { crop: [.17224880, .03508772, .63636364, .93062201], aspect: 1.46240602 },
  };
  let host = { connected: false, connecting: false, disconnecting: false, busy: true,
    enabled: false, canCancel: false, active: true, motion: true, mode: 'blocked_only',
    source: 'Источник VPN', message: '', error: false };
  let ready = false, phase = 'loading', logicalState = 'idle', phaseStart = performance.now();
  let duration = 1, transitionFrom = null, connectedAt = 0, lastTimer = '';
  let raf = 0, stillTimer = 0, lastPaint = -Infinity, lastTick = null, sceneClock = 0;
  let visible = document.visibilityState !== 'hidden', intersecting = true, pausedAt = null;
  let w = 390, h = 610, dpr = 1, spaceW = 390, spaceH = 760, nebula = null;
  let renderer, world, camera, earth, earthUniforms, sprites;
  let lastView = null;

  function send(action, value) { globalThis.DropoScene?.postMessage(JSON.stringify({ action, value })); }
  function connectionState() {
    if (host.disconnecting) return 'disconnecting';
    if (host.connected) return 'connected';
    if (host.connecting) return 'connecting';
    return host.error ? 'error' : 'idle';
  }
  // This runs synchronously on a native update, never on an animation completion.
  // Native enabled/canCancel remain authoritative even when connected is already true.
  function syncControls() {
    logicalState = connectionState();
    const connected = logicalState === 'connected';
    const resting = logicalState === 'idle' || logicalState === 'error';
    main.dataset.state = logicalState;
    main.dataset.busy = String(host.busy || host.connecting || host.disconnecting);
    details.hidden = !connected;
    details.inert = !connected;
    cancel.hidden = !ready || !host.canCancel || host.connected || host.disconnecting;
    earthAction.disabled = !ready || host.disconnecting || (!host.enabled && !host.canCancel);
    power.disabled = !ready || !host.enabled || !resting;
    power.hidden = !resting;
    hint.hidden = !resting;
    service.disabled = all.disabled = !ready || !host.enabled || !connected;
    $('.dp-disconnect').disabled = !ready || !host.enabled || !connected;
    $('.dp-source-row').disabled = !ready || !host.enabled || !connected;
    $('.dp-services').disabled = !ready || !host.enabled || !connected;
    const error = logicalState === 'error';
    power.setAttribute('aria-label', error ? 'Повторить подключение VPN' : 'Подключить VPN');
    hint.querySelector('span').textContent = error ? 'Попробовать ещё раз' : 'Подключиться';
    earthAction.setAttribute('aria-label', connected ? 'Отключить VPN нажатием на Землю' :
      host.canCancel ? 'Отменить подключение VPN' : error ? 'Повторить подключение VPN' : 'Подключить VPN нажатием на Землю');
    const text = connected ? 'VPN подключён' : logicalState === 'connecting' ? 'Подключаем VPN' :
      logicalState === 'disconnecting' ? 'Отключаем VPN' : error ? 'Не удалось подключиться' :
      host.busy ? 'Подготавливаем VPN' : 'Не подключено';
    if (status.textContent !== text) status.textContent = text;
  }
  function setMode() {
    const full = host.mode === 'all_traffic';
    service.setAttribute('aria-pressed', String(!full));
    all.setAttribute('aria-pressed', String(full));
    $('.dp-mode-pill').style.transform = full ? 'translateX(100%)' : 'translateX(0)';
    $('.dp-mode-note').textContent = full ? 'Весь интернет-трафик через VPN; локальная сеть — напрямую' :
      'Выбранные сервисы через VPN, остальное — напрямую';
    $('.dp-services-row').hidden = full;
  }
  function layout(zoom) {
    const big = Math.min(322, w * .88);
    return { cx: w / 2, cy: mix(Math.min(h * .48, h - 278), Math.min(236, h - 420), zoom),
      d: mix(big, Math.min(240, w * .66), zoom), big };
  }
  function seated() {
    const b = layout(0), width = 104 * b.d / b.big;
    return { x: b.cx, y: b.cy - b.d * .432 - width * artInfo.waiting.aspect * .22,
      width, z: b.d * .56, roll: 0 };
  }
  function puzzled() {
    const b = layout(0), width = 100 * b.d / b.big;
    return { x: b.cx, y: b.cy - b.d * .432 - width * artInfo.puzzled.aspect * .30,
      width, z: b.d * .56, roll: 0 };
  }
  function hero() {
    const b = layout(1), width = 114;
    return { x: b.cx + b.d * .24, y: Math.max(92, b.cy - b.d * .432 - 25), width, z: b.d * .65, roll: .12 };
  }
  function orbit(progress) {
    const b = layout(0), a = Math.PI * .1 + progress * Math.PI * 2;
    const width = Math.min(92, w * .24), radius = b.d * .432 + width * .48 + 12;
    return { x: b.cx + Math.cos(a) * radius * .66, y: b.cy - Math.cos(a) * radius * .75,
      width, z: Math.sin(a) * radius, roll: Math.cos(a) * .10 };
  }
  function blendPose(a, b, p) {
    const pose = {};
    for (const key of ['x', 'y', 'width', 'z', 'roll']) pose[key] = mix(a[key], b[key], p);
    return pose;
  }
  function restingView(target) {
    const connected = target === 'connected', error = target === 'error';
    return { zoom: connected ? 1 : 0, glow: connected ? 1 : 0, error: error ? 1 : 0,
      pose: connected ? hero() : error ? puzzled() : seated(),
      weights: { waiting: connected || error ? 0 : 1, flying: connected ? 1 : 0, puzzled: error ? 1 : 0 } };
  }
  function blendView(a, b, p) {
    const view = { pose: blendPose(a.pose, b.pose, p), weights: {} };
    for (const key of ['zoom', 'glow', 'error']) view[key] = mix(a[key], b[key], p);
    for (const kind of Object.keys(artInfo)) view.weights[kind] = mix(a.weights[kind], b.weights[kind], p);
    return view;
  }
  function setPhase(next, seconds = 1, now = performance.now()) {
    phase = next; phaseStart = now; duration = seconds; main.dataset.phase = next;
    // Native updates can arrive while hidden: a fresh transition starts on resume.
    if (pausedAt !== null) pausedAt = now;
  }
  function transition(next, seconds) {
    transitionFrom = lastView || restingView('idle');
    setPhase(next, seconds);
  }
  function reconcile() {
    syncControls();
    if (!ready) return;
    if (!settings.motion) {
      setPhase(logicalState === 'connecting' ? 'orbit' : logicalState);
      return;
    }
    if (logicalState === 'connected') {
      if (!['connected', 'arrive'].includes(phase)) transition('arrive', .45);
    } else if (logicalState === 'connecting') {
      if (!['launch', 'orbit'].includes(phase)) transition('launch', .65);
    } else if (logicalState === 'error') {
      if (phase !== 'error') transition('error', .4);
    } else if (!['idle', 'return', 'disconnecting'].includes(phase)) {
      transition('return', .5);
    }
  }
  const stars=Array.from({length:156},(_,i)=>{const rand=n=>{const x=Math.sin(i*127.1+n*311.7+71.4)*43758.5453;return x-Math.floor(x);};return{x:rand(1),y:rand(2),layer:rand(3),r:.35+rand(4)*.8,phase:rand(5)*Math.PI*2};});
  function prepareNebula(){nebula=document.createElement('canvas');nebula.width=Math.ceil(spaceW+120);nebula.height=Math.ceil(spaceH+120);const n=nebula.getContext('2d');n.fillStyle='#030908';n.fillRect(0,0,nebula.width,nebula.height);const clouds=[[.15,.26,.85,'#10362f30'],[.91,.54,.78,'#16392a24'],[.2,.93,.64,'#15223b26']];for(const[x,y,r,color]of clouds){const radius=spaceW*r,g=n.createRadialGradient(nebula.width*x,nebula.height*y,0,nebula.width*x,nebula.height*y,radius);g.addColorStop(0,color);g.addColorStop(1,'#00000000');n.fillStyle=g;n.fillRect(0,0,nebula.width,nebula.height);}}
  function drawSpace(t){
    space.clearRect(0,0,spaceW,spaceH);if(nebula)space.drawImage(nebula,-60+Math.sin(t/44)*24,-60+Math.cos(t/57)*20);
    for(let i=0;i<stars.length;i++){const star=stars[i],speed=.35+star.layer*1.5,x=(star.x*spaceW+t*speed*.70+spaceW*3)%spaceW,y=(star.y*spaceH+t*speed*.27+spaceH*3)%spaceH,alpha=(.22+star.layer*.36)*(.72+.28*Math.sin(t*(.65+star.layer*.6)+star.phase));space.fillStyle=`rgba(${i%5===0?'157,206,226':'209,234,222'},${alpha})`;space.beginPath();space.arc(x,y,star.r,0,Math.PI*2);space.fill();if(i%37===0){space.strokeStyle=`rgba(217,238,241,${alpha*.4})`;space.lineWidth=.6;space.beginPath();space.moveTo(x-2.5,y);space.lineTo(x+2.5,y);space.moveTo(x,y-2.5);space.lineTo(x,y+2.5);space.stroke();}}
    const streak=(t+9)%23;if(streak<1.0){const p=streak,x=spaceW*.74-p*spaceW*.26,y=spaceH*.15+p*spaceH*.09,g=space.createLinearGradient(x,y,x+34,y-13);g.addColorStop(0,`rgba(199,228,225,${Math.sin(p*Math.PI)*.3})`);g.addColorStop(1,'#d1eeea00');space.strokeStyle=g;space.lineWidth=.8;space.beginPath();space.moveTo(x,y);space.lineTo(x+34,y-13);space.stroke();}
  }

  function createSprite(T, image, kind) {
    const info = artInfo[kind], texture = new T.Texture(image), c = info.crop;
    texture.colorSpace = T.SRGBColorSpace;
    texture.offset.set(c[0], 1 - c[1] - c[3]); texture.repeat.set(c[2], c[3]); texture.needsUpdate = true;
    const material = new T.MeshBasicMaterial({ map: texture, transparent: true,
      alphaTest: .008, depthWrite: false, side: T.DoubleSide, toneMapped: false });
    // Keep DrOppo's original green colors in every pose, including errors.
    const mesh = new T.Mesh(new T.PlaneGeometry(1, info.aspect), material);
    world.add(mesh);
    return { mesh, material };
  }
  function initWorld(images) {
    const T = globalThis.THREE;
    if (!T) throw new Error('3D engine unavailable');
    renderer = new T.WebGLRenderer({ canvas, alpha: true, antialias: true,
      premultipliedAlpha: true, powerPreference: 'low-power' });
    renderer.setClearColor(0, 0); renderer.outputColorSpace = T.SRGBColorSpace; renderer.toneMapping = T.NoToneMapping;
    world = new T.Scene(); camera = new T.OrthographicCamera(-w/2, w/2, h/2, -h/2, .1, 2500); camera.position.z = 1200;
    const map = new T.Texture(images.earth); map.needsUpdate = true; map.wrapS = T.RepeatWrapping;
    map.anisotropy = Math.min(4, renderer.capabilities.getMaxAnisotropy());
    earthUniforms = { map: { value: map }, glow: { value: 0 }, error: { value: 0 } };
    const material = new T.ShaderMaterial({ uniforms: earthUniforms, vertexShader: `
      varying vec2 texUv; varying vec3 viewNormal;
      void main(){texUv=uv;viewNormal=normalize(normalMatrix*normal);gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0);}
    `, fragmentShader: `
      uniform sampler2D map; uniform float glow; uniform float error; varying vec2 texUv; varying vec3 viewNormal;
      void main(){
        vec3 c=texture2D(map,texUv).rgb;float lum=dot(c,vec3(.2126,.7152,.0722));
        float gold=clamp((c.r-c.b-.031)/.216,0.,1.)*clamp((c.g-c.b-.012)/.176,0.,1.)*clamp((lum-.11)/.33,0.,1.);
        float terrain=mix(lum,min(lum,.106),gold);vec3 gray=vec3(.035+terrain*1.10);
        float g=max(c.g,.071+lum*1.12);vec3 green=mix(vec3(min(c.r,g*.74),g,min(c.b,g*.82)),c,gold);
        vec3 red=vec3(.075+lum*1.30,.019+lum*.22,.025+lum*.19);
        float facing=max(normalize(viewNormal).z,0.);float shading=.70+.30*pow(facing,.38);
        vec3 col=mix(mix(gray,green,glow),red,error)*shading;
        float rim=pow(1.-facing,3.5);
        col+=mix(mix(vec3(.10,.12,.12),vec3(.04,.29,.21),glow),vec3(.40,.035,.045),error)*rim;
        gl_FragColor=vec4(col,1.);
      }
    ` });
    earth = new T.Mesh(new T.SphereGeometry(1, 128, 80), material); world.add(earth);
    sprites = Object.fromEntries(Object.keys(artInfo).map(kind => [kind, createSprite(T, images[kind], kind)]));
    main.dataset.mascotArt = 'canonical-droppo';
    resize(); renderer.compile(world, camera);
  }
  function drawHalo(b, view) {
    halo.clearRect(0, 0, w, h);
    const r = b.d * .432, g = halo.createRadialGradient(b.cx,b.cy,r*.97,b.cx,b.cy,r*1.12);
    const rgb = [mix(mix(191,103,view.glow),255,view.error),mix(mix(204,232,view.glow),86,view.error),mix(mix(199,191,view.glow),99,view.error)].map(Math.round).join(',');
    g.addColorStop(0,`rgba(${rgb},0)`);g.addColorStop(.35,`rgba(${rgb},.22)`);g.addColorStop(1,`rgba(${rgb},0)`);
    halo.fillStyle=g;halo.beginPath();halo.arc(b.cx,b.cy,r*1.12,0,Math.PI*2);halo.fill();
  }
  function drawArrow(){
    const c=hint.querySelector('canvas');c.width=360;c.height=400;const ctx=c.getContext('2d');ctx.scale(2,2);
    const angle=Math.PI/6,tx=90+39*Math.sin(angle),ty=39*Math.cos(angle);
    ctx.strokeStyle='#fff';ctx.lineCap='round';ctx.lineJoin='round';ctx.lineWidth=2;ctx.beginPath();ctx.moveTo(124,187);ctx.bezierCurveTo(173,157,tx+29,ty+51,tx,ty);ctx.stroke();
    ctx.globalAlpha=.32;ctx.lineWidth=1;ctx.beginPath();ctx.moveTo(123,188);ctx.bezierCurveTo(171,159,tx+31,ty+53,tx,ty);ctx.stroke();
    ctx.globalAlpha=1;ctx.lineWidth=2;ctx.beginPath();ctx.moveTo(tx-1,ty+18);ctx.quadraticCurveTo(tx+1,ty+7,tx,ty);ctx.quadraticCurveTo(tx+8,ty+7,tx+16,ty+9);ctx.stroke();
  }

  function draw(now) {
    if (lastTick !== null && settings.motion) sceneClock += Math.min(100, now - lastTick) / 1000;
    lastTick = now;
    const t = sceneClock, p = clamp((now - phaseStart) / 1000 / duration), s = smooth(p);
    let view;
    if (!settings.motion) {
      view = restingView(logicalState);
      if (logicalState === 'connecting') view = { ...restingView('connected'), zoom: 0, glow: .2, pose: orbit(0) };
    } else if (phase === 'launch') {
      const target = { ...restingView('connected'), zoom: 0, glow: .18, pose: orbit(0) };
      view = blendView(transitionFrom, target, s);
      view.pose.y -= Math.sin(p * Math.PI) * 10;
      if (p >= 1) setPhase('orbit', 6, now);
    } else if (phase === 'orbit') {
      view = { ...restingView('connected'), zoom: 0, glow: .2 + .08 * Math.sin(t), pose: orbit(p) };
      if (p >= 1) setPhase('orbit', 6, now);
    } else if (phase === 'arrive') {
      view = blendView(transitionFrom, restingView('connected'), s);
      if (p >= 1) setPhase('connected', 1, now);
    } else if (phase === 'return') {
      view = blendView(transitionFrom, restingView('idle'), s);
      if (p >= 1) setPhase('idle', 1, now);
    } else if (phase === 'error') {
      view = transitionFrom ? blendView(transitionFrom, restingView('error'), s) : restingView('error');
    } else view = restingView(logicalState);
    // Only the artwork moves. Native availability never waits for this drawing.
    if (settings.motion && ['idle', 'connected', 'error'].includes(phase)) {
      view.pose.y += Math.sin(t * .9) * (phase === 'connected' ? 2 : .65);
      view.pose.roll += phase === 'error' ? Math.sin(t * .85) * .035 : Math.sin(t * .65) * .018;
    }
    lastView = view;
    const b = layout(view.zoom);
    drawSpace(t); drawHalo(b, view);
    if (renderer) {
      earth.position.set(b.cx-w/2,h/2-b.cy,0);earth.scale.setScalar(b.d*.432);
      earth.rotation.set(.21,-1.77+t*Math.PI*2/100,-.08,'XYZ');
      earthUniforms.glow.value=view.glow;earthUniforms.error.value=view.error;
      for (const [kind, sprite] of Object.entries(sprites)) {
        const alpha = view.weights[kind], pose = view.pose;
        sprite.mesh.visible = alpha > .001;
        sprite.material.opacity = alpha;
        // Keep the approved face facing the viewer through the orbit.
        sprite.mesh.rotation.set(0,0,pose.roll);
        sprite.mesh.position.set(pose.x-w/2,h/2-pose.y,pose.z);
        sprite.mesh.scale.setScalar(pose.width);
        sprite.mesh.renderOrder = kind === 'flying' ? 2 : 3;
      }
      renderer.render(world,camera);
    }
    // Error/retry controls follow the resting globe, not the departing flight.
    const resting = layout(0), hit = b.d*.86;
    Object.assign(power.style,{left:resting.cx+'px',top:resting.cy+'px'});
    const hintY = logicalState === 'error' ? resting.cy + resting.d * .432 + 22 : resting.cy;
    Object.assign(hint.style,{left:resting.cx+'px',top:hintY+'px'});
    Object.assign(earthAction.style,{left:(b.cx-hit/2)+'px',top:(b.cy-hit/2)+'px',width:hit+'px',height:hit+'px'});
    updateTimer();
  }
  function updateTimer() {
    if (!connectedAt) return;
    const seconds = Math.floor(Math.max(0,Date.now()-connectedAt)/1000);
    const value = String(Math.floor(seconds/60)).padStart(2,'0')+':'+String(seconds%60).padStart(2,'0');
    if(value!==lastTimer){timer.textContent=value;lastTimer=value;}
  }
  function frame(now) {
    raf=0;
    if(!visible||!intersecting||!ready)return;
    if(!settings.motion||now-lastPaint>=1000/30-1){lastPaint=now;draw(now);}
    if(settings.motion&&!raf)raf=requestAnimationFrame(frame);
    else if((host.connected||host.connecting)&&!stillTimer)stillTimer=setTimeout(()=>{stillTimer=0;wake();},500);
  }
  function wake(){if(ready&&!raf&&visible&&intersecting)raf=requestAnimationFrame(frame);}
  function update(next) {
    const wasConnected=host.connected;host={...host,...next};
    const previousMotion=settings.motion;
    settings.motion=host.motion&&!mq.matches;
    if(ready&&previousMotion!==settings.motion){
      // A preference change must not replay an old success/error transition.
      transitionFrom=null;
      const state=connectionState();
      setPhase(state==='connecting'?'orbit':state==='disconnecting'?'idle':state,state==='connecting'?6:1);
      lastView=restingView(state);
    }
    if(host.connected){
      if(Number.isFinite(host.connectedAt)&&host.connectedAt>0)connectedAt=host.connectedAt;
      else if(!wasConnected)connectedAt=Date.now();
    }
    if(!host.connected&&!host.connecting){connectedAt=0;lastTimer='';timer.textContent='00:00';}
    setMode();$('.dp-source-name').textContent=host.source;
    const message=$('.dp-message');message.hidden=!host.message;message.textContent=host.message;
    reconcile();updateTimer();visibilityChanged();lastPaint=-Infinity;wake();
  }
  function activate(){if(!ready)return;if(host.canCancel&&!host.connected)send('cancel');else if(host.enabled)send('toggle');}
  window.DropoHome={update};
  power.addEventListener('click',activate);earthAction.addEventListener('click',activate);
  cancel.addEventListener('click',()=>{if(host.canCancel)send('cancel');});
  $('.dp-disconnect').addEventListener('click',()=>{if(host.enabled&&host.connected&&!host.disconnecting)send('toggle');});
  service.addEventListener('click',()=>{if(host.enabled&&logicalState==='connected')send('mode','blocked_only');});
  all.addEventListener('click',()=>{if(host.enabled&&logicalState==='connected')send('mode','all_traffic');});
  $('.dp-source-row').addEventListener('click',()=>{if(host.enabled&&logicalState==='connected')send('sources');});
  $('.dp-services').addEventListener('click',()=>{if(host.enabled&&logicalState==='connected')send('services');});
  $('.dp-message').addEventListener('click',()=>send('help'));
  function visibilityChanged(){
    visible=document.visibilityState!=='hidden'&&host.active;
    if(!visible||!intersecting){if(pausedAt===null)pausedAt=performance.now();if(raf)cancelAnimationFrame(raf);raf=0;clearTimeout(stillTimer);stillTimer=0;lastTick=null;}
    else if(pausedAt!==null){phaseStart+=performance.now()-pausedAt;pausedAt=null;lastTick=null;wake();}
  }
  document.addEventListener('visibilitychange',visibilityChanged);
  new IntersectionObserver(entries=>{intersecting=entries[0].isIntersecting;visibilityChanged();if(intersecting)wake();},{threshold:.01}).observe(root);
  mq.addEventListener('change',()=>update(host));
  function resize(){
    const rect=scene.getBoundingClientRect();w=rect.width||390;h=rect.height||610;dpr=Math.min(devicePixelRatio||1,2);
    const bounds=phone.getBoundingClientRect();spaceW=bounds.width||390;spaceH=bounds.height||760;
    haloCanvas.width=Math.round(w*dpr);haloCanvas.height=Math.round(h*dpr);halo.setTransform(dpr,0,0,dpr,0,0);
    spaceCanvas.width=Math.round(spaceW*dpr);spaceCanvas.height=Math.round(spaceH*dpr);space.setTransform(dpr,0,0,dpr,0,0);prepareNebula();
    if(renderer){renderer.setPixelRatio(dpr);renderer.setSize(w,h,false);camera.left=-w/2;camera.right=w/2;camera.top=h/2;camera.bottom=-h/2;camera.updateProjectionMatrix();}
    details.style.top=(layout(1).cy+116)+'px';cancel.style.top=Math.min(h-70,layout(0).cy+195)+'px';lastPaint=-Infinity;wake();
  }
  new ResizeObserver(resize).observe(scene);
  function loadImage(url){return new Promise((resolve,reject)=>{const im=new Image();im.onload=()=>resolve(im);im.onerror=()=>reject(new Error('Scene asset unavailable'));im.src=url;});}
  setMode();drawArrow();resize();syncControls();
  Promise.all(Object.entries(window.DropoArt).map(async([key,url])=>[key,await loadImage(url)])).then(pairs=>{
    initWorld(Object.fromEntries(pairs));ready=true;lastView=restingView(connectionState());
    setPhase(connectionState()==='connecting'?'idle':connectionState());reconcile();send('ready');lastPaint=-Infinity;wake();
  }).catch(error=>{status.textContent='Не удалось запустить сцену';main.dataset.error=error.message;ready=false;if(raf)cancelAnimationFrame(raf);raf=0;send('failed');});
  canvas.addEventListener('webglcontextlost',event=>{event.preventDefault();if(raf)cancelAnimationFrame(raf);raf=0;ready=false;send('failed');});
  window.addEventListener('pagehide',()=>{if(raf)cancelAnimationFrame(raf);clearTimeout(stillTimer);renderer?.dispose();renderer?.forceContextLoss();});
})();

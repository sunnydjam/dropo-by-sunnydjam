// Local presentation only: native Flutter/CoreBridge owns connection and control availability.
(() => {
  const root = document.getElementById('dropo-motion-preview');
  const $ = selector => root.querySelector(selector);
  const phone = $('.dp-phone'), main = $('.dp-main'), scene = $('.dp-scene');
  const power = $('.dp-start'), earthAction = $('.dp-earth-action'), hint = $('.dp-hint');
  const disconnect = $('.dp-disconnect');
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
    enabled: false, canCancel: false, active: false, motion: true, mode: 'blocked_only',
    language: 'ru', source: '', responseMs: null, message: '', error: false };
  let ready = false, presented = false, hostReceived = false;
  let geometry = '', layoutRevision = 0, stableFrames = 0;
  let phase = 'loading', logicalState = 'idle', phaseStart = performance.now();
  const orbitSeconds = 2.7;
  let duration = 1, transitionFrom = null, connectedAt = 0, lastTimer = '';
  let raf = 0, stillTimer = 0, lastPaint = -Infinity, lastTick = null, sceneClock = 0;
  let visible = document.visibilityState !== 'hidden', intersecting = true, pausedAt = null;
  let w = 390, h = 610, dpr = 1, spaceW = 390, spaceH = 760, nebula = null;
  let renderer, world, camera, earth, earthUniforms, sprites, flight;
  let lastView = null, lastSpacePaint = -Infinity, haloKey = null;
  let retryArrow;

  const en = () => host.language === 'en';
  const text = (ru, english) => en() ? english : ru;

  function translateControls() {
    document.documentElement.lang = en() ? 'en' : 'ru';
    document.title = text('Подключение Dropo', 'Dropo connection');
    phone.setAttribute('aria-label', document.title);
    scene.setAttribute('aria-label', text('Земля и DrOppo', 'Earth and DrOppo'));
    details.setAttribute('aria-label', text('Параметры подключения', 'Connection settings'));
    $('.dp-mode').setAttribute('aria-label', text('Режим VPN', 'VPN mode'));
    $('.dp-message').setAttribute('aria-label', text('Подробности ошибки подключения', 'Connection error details'));
    $('.dp-source-row').setAttribute('aria-label', text('Выбрать источник VPN', 'Choose a VPN source'));
    $('.dp-source-row > span:nth-child(2)').textContent = text('Источник', 'Source');
    $('.dp-time-row > span:nth-child(2)').textContent = text('Время сессии', 'Session time');
    $('.dp-services').textContent = text('Настроить сервисы', 'Configure services');
    $('.dp-disconnect span').textContent = text('Отключить', 'Disconnect');
    service.textContent = text('По сервисам', 'By service');
    all.textContent = text('Всё через VPN', 'All traffic via VPN');
    cancel.textContent = text('Отменить подключение', 'Cancel connection');
  }

  function send(action, value) {
    if (!presented && action !== 'ready' && action !== 'failed') return;
    globalThis.DropoScene?.postMessage(JSON.stringify({ action, value }));
  }
  function connectionState() {
    if (host.disconnecting) return 'disconnecting';
    if (host.connected) return 'connected';
    if (host.connecting) return 'connecting';
    return host.error ? 'error' : 'idle';
  }
  function syncConnectedPanel() {
    const resting = logicalState === 'idle' || logicalState === 'error';
    const show = presented && (resting || logicalState === 'connected');
    details.hidden = !show;
    details.inert = !show;
    details.classList.toggle('dp-setup', resting);
    const disabled = !show || !host.enabled;
    service.disabled = all.disabled = disabled;
    disconnect.disabled = disabled || resting;
    $('.dp-source-row').disabled = $('.dp-services').disabled = disabled;
  }

  function syncControls() {
    logicalState = connectionState();
    const resting = logicalState === 'idle' || logicalState === 'error';
    main.dataset.state = logicalState;
    main.dataset.busy = String(host.busy || host.connecting || host.disconnecting);
    syncConnectedPanel();
    cancel.hidden = !presented || !host.canCancel || host.connected || host.disconnecting;
    power.disabled = earthAction.disabled = !presented || !host.enabled || !resting;
    earthAction.hidden = !resting;
    power.hidden = !resting;
    hint.hidden = !resting;

    const error = logicalState === 'error';
    if (retryArrow !== error) {
      retryArrow = error;
      drawArrow(error);
    }
    const retry = text('Повторить подключение VPN', 'Retry VPN connection');
    power.setAttribute('aria-label', error ? retry : text('Подключить VPN', 'Connect VPN'));
    hint.querySelector('span').textContent = error ? text('Попробовать снова', 'Try again') :
      text('Подключиться', 'Connect');
    earthAction.setAttribute('aria-label', error ? retry :
      text('Подключить VPN нажатием на Землю', 'Tap Earth to connect VPN'));
    const label = logicalState === 'connected' ? text('VPN подключён', 'VPN connected') :
      logicalState === 'connecting' ? text('Проверяем соединение…', 'Checking connection…') :
      logicalState === 'disconnecting' ? text('Отключаем VPN', 'Disconnecting VPN') :
      error ? text('Не удалось подключиться', 'Connection failed') :
      host.busy ? text('Подготавливаем VPN', 'Preparing VPN') : text('Не подключено', 'Disconnected');
    if (status.textContent !== label) status.textContent = label;
  }
  function setMode() {
    const full = host.mode === 'all_traffic';
    service.setAttribute('aria-pressed', String(!full));
    all.setAttribute('aria-pressed', String(full));
    $('.dp-mode-pill').style.transform = full ? 'translateX(100%)' : 'translateX(0)';
    $('.dp-mode-note').textContent = full ?
      text('Весь интернет-трафик через VPN; локальная сеть — напрямую', 'All internet traffic uses VPN. Local traffic stays direct.') :
      text('Выбранные сервисы через VPN, остальное — напрямую', 'Selected services use VPN. Other traffic stays direct.');
    $('.dp-services-row').hidden = full;
  }
  function layout(zoom) {
    const big = Math.min(322, w * .88);
    return { cx: w / 2, cy: mix(Math.min(h * .43, h - 325), Math.min(236, h - 420), zoom),
      d: mix(big, Math.min(240, w * .66), zoom), big };
  }
  function seated() {
    const b = layout(0), width = 104 * b.d / b.big;
    return { x: b.cx, y: b.cy - b.d * .432 - width * artInfo.waiting.aspect * .22,
      width, z: b.d * .56, yaw: 0, roll: 0 };
  }
  function puzzled() {
    const b = layout(0), width = 100 * b.d / b.big;
    return { x: b.cx, y: b.cy - b.d * .432 - width * artInfo.puzzled.aspect * .30,
      width, z: b.d * .56, yaw: 0, roll: 0 };
  }
  function hero() {
    const b = layout(1), width = 114;
    return { x: b.cx + b.d * .24, y: Math.max(92, b.cy - b.d * .432 - 25), width, z: b.d * .65, yaw: 0, roll: .12 };
  }
  function orbit(progress) {
    const b = layout(0), a = Math.PI * .1 + progress * Math.PI * 2;
    const width = Math.min(86, w * .205);
    const radius = b.d * .432 + width * .65 + 12;
    const rearTurn = Math.PI * 2 * smooth((a - Math.PI * 1.05) / (Math.PI * .9));
    return { x: b.cx + Math.cos(a) * radius * .66, y: b.cy - Math.cos(a) * radius * .75,
      width, z: Math.sin(a) * radius, yaw: rearTurn + Math.sin(a + .3) * .18, roll: Math.cos(a) * .10 };
  }
  function blendPose(a, b, p) {
    const pose = {};
    for (const key of ['x', 'y', 'width', 'z', 'yaw', 'roll']) pose[key] = mix(a[key], b[key], p);
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
    syncConnectedPanel();
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
      if (!['connected', 'arrive'].includes(phase)) {
        if (presented && host.active) transition('arrive', .42);
        else setPhase('connected');
      }
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
  function createFlyingVolume(T,frontImage,rearImage){
    const info=artInfo.flying,crop=info.crop.map((value,i)=>value*(i%2?frontImage.height:frontImage.width)),aspect=info.aspect,nx=128,ny=100,stride=nx+1,count=stride*(ny+1);
    const sample=document.createElement('canvas');sample.width=stride;sample.height=ny+1;const ctx=sample.getContext('2d',{willReadFrequently:true});ctx.drawImage(frontImage,...crop,0,0,stride,ny+1);const pixels=ctx.getImageData(0,0,stride,ny+1).data;
    const inside=new Uint8Array(count),dist=new Float32Array(count);
    for(let i=0;i<count;i++){inside[i]=pixels[i*4+3]>20?1:0;dist[i]=inside[i]?1000:0;}
    for(let y=1;y<=ny;y++)for(let x=1;x<=nx;x++){const i=y*stride+x;if(inside[i])dist[i]=Math.min(dist[i],dist[i-1]+1,dist[i-stride]+1,dist[i-stride-1]+1.414);}
    for(let y=ny-1;y>=0;y--)for(let x=nx-1;x>=0;x--){const i=y*stride+x;if(inside[i])dist[i]=Math.min(dist[i],dist[i+1]+1,dist[i+stride]+1,dist[i+stride+1]+1.414);}
    const positions=[],uvs=[],colors=[],cells=new Uint8Array(nx*ny);let radius=0;
    const ellipse=(x,y,cx,cy,rx,ry)=>Math.sqrt(Math.max(0,1-Math.pow((x-cx)/rx,2)-Math.pow((y-cy)/ry,2)));
    for(const sign of [1,-1])for(let y=0;y<=ny;y++)for(let x=0;x<=nx;x++){
      const i=y*stride+x,u=x/nx,v=y/ny;
      const head=.235*ellipse(u,v,.685,.29,.245,.295),torso=.145*ellipse(u,v,.51,.64,.255,.27),fist=.085*ellipse(u,v,.925,.455,.09,.12),boots=.075*ellipse(u,v,.36,.89,.18,.15);
      const thickness=(.013+Math.max(head,torso,fist,boots))*smooth(dist[i]/3.2),px=u-.5,py=(.5-v)*aspect,pz=thickness*sign;
      positions.push(px,py,pz);uvs.push(u,1-v);radius=Math.max(radius,Math.hypot(px,py,pz));
      let si=i;if(!inside[i])for(let dy=-2;dy<=2;dy++)for(let dx=-2;dx<=2;dx++){const j=(y+dy)*stride+x+dx;if(x+dx>=0&&x+dx<=nx&&y+dy>=0&&y+dy<=ny&&inside[j])si=j;}
      const c=new T.Color(pixels[si*4]/255,pixels[si*4+1]/255,pixels[si*4+2]/255).convertSRGBToLinear();colors.push(c.r,c.g,c.b);
    }
    for(let y=0;y<ny;y++)for(let x=0;x<nx;x++){const a=y*stride+x;cells[y*nx+x]=(inside[a]||inside[a+1]||inside[a+stride]||inside[a+stride+1])?1:0;}
    const front=[],back=[],sides=[];
    const edge=(a,b)=>{sides.push(a,a+count,b,b,a+count,b+count);};
    for(let y=0;y<ny;y++)for(let x=0;x<nx;x++){
      if(!cells[y*nx+x])continue;const a=y*stride+x,b=a+1,c=a+stride,d=c+1;
      front.push(a,c,b,b,c,d);back.push(a+count,b+count,c+count,b+count,d+count,c+count);
      if(y===0||!cells[(y-1)*nx+x])edge(b,a);if(x===nx-1||!cells[y*nx+x+1])edge(d,b);if(y===ny-1||!cells[(y+1)*nx+x])edge(c,d);if(x===0||!cells[y*nx+x-1])edge(a,c);
    }
    const geometry=new T.BufferGeometry();geometry.setAttribute('position',new T.Float32BufferAttribute(positions,3));geometry.setAttribute('uv',new T.Float32BufferAttribute(uvs,2));geometry.setAttribute('color',new T.Float32BufferAttribute(colors,3));geometry.setIndex([...front,...back,...sides]);geometry.addGroup(0,front.length,0);geometry.addGroup(front.length,back.length,1);geometry.addGroup(front.length+back.length,sides.length,2);geometry.computeVertexNormals();
    function texture(im,bounds){const tex=new T.Texture(im);tex.colorSpace=T.SRGBColorSpace;tex.offset.set(bounds[0],1-bounds[1]-bounds[3]);tex.repeat.set(bounds[2],bounds[3]);tex.needsUpdate=true;return tex;}
    const frontTex=texture(frontImage,crop.map((n,i)=>n/(i%2?frontImage.height:frontImage.width)));
    const rearTex=texture(rearImage,[35/1254,168/1254,1128/1254,973/1254]);
    const frontMaterial=new T.MeshBasicMaterial({map:frontTex,transparent:true,alphaTest:.012,depthWrite:true,toneMapped:false});
    const backMaterial=new T.MeshBasicMaterial({map:rearTex,transparent:true,depthWrite:true,toneMapped:false});
    const sideMaterial=new T.MeshBasicMaterial({vertexColors:true,transparent:true,depthWrite:true,toneMapped:false});
    const uniforms={time:{value:0},bored:{value:0},motion:{value:1}},materials=[frontMaterial,backMaterial,sideMaterial];
    materials.forEach((material,index)=>{
      material.customProgramCacheKey=()=>`droppo-closed-volume-${index}`;
      material.onBeforeCompile=shader=>{
        shader.uniforms.dpTime=uniforms.time;shader.uniforms.dpMotion=uniforms.motion;
        shader.vertexShader='uniform float dpTime;uniform float dpMotion;\n'+shader.vertexShader;
        shader.vertexShader=shader.vertexShader.replace('#include <begin_vertex>',`#include <begin_vertex>
          vec2 p=vec2(uv.x,1.0-uv.y);float cape=(1.0-smoothstep(.22,.56,p.x))*smoothstep(.25,.62,p.y);
          transformed.z+=sin(dpTime*2.5+p.x*8.0)*.018*cape*dpMotion;
          transformed.y+=sin(dpTime*2.5+p.x*8.0)*.007*cape*dpMotion;
          float head=smoothstep(.44,.60,p.x)*(1.0-smoothstep(.44,.57,p.y));
          transformed.x+=head*sin(dpTime*.85)*.004*dpMotion;
          transformed.y+=head*sin(dpTime*1.15)*.004*dpMotion;
        `);
        if(index===1)shader.fragmentShader=shader.fragmentShader.replace('#include <map_fragment>','#include <map_fragment>\n diffuseColor.rgb=mix(vec3(.025,.16,.10),diffuseColor.rgb,step(.04,diffuseColor.a));diffuseColor.a=opacity;');
      };
    });
    const mesh=new T.Mesh(geometry,materials);mesh.renderOrder=2;world.add(mesh);
    main.dataset.mascotGeometry='closed-volume';main.dataset.mascotTriangles=String((front.length+back.length+sides.length)/3);
    return{mesh,material:frontMaterial,materials,uniforms,volume:true,radius,head:info.head,span:info.span,aspect};
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
    sprites.flying.mesh.visible = false;
    flight = createFlyingVolume(T, images.flying, images.rear);
    main.dataset.mascotArt = 'canonical-droppo';
    resize(true); renderer.compile(world, camera);
  }
  function drawHalo(b, view) {
    halo.clearRect(0, 0, w, h);
    const r = b.d * .432, g = halo.createRadialGradient(b.cx,b.cy,r*.97,b.cx,b.cy,r*1.12);
    const rgb = [mix(mix(191,103,view.glow),255,view.error),mix(mix(204,232,view.glow),86,view.error),mix(mix(199,191,view.glow),99,view.error)].map(Math.round).join(',');
    g.addColorStop(0,`rgba(${rgb},0)`);g.addColorStop(.35,`rgba(${rgb},.22)`);g.addColorStop(1,`rgba(${rgb},0)`);
    halo.fillStyle=g;halo.beginPath();halo.arc(b.cx,b.cy,r*1.12,0,Math.PI*2);halo.fill();
  }
  function drawArrow(retry){
    const c=hint.querySelector('canvas');c.width=360;c.height=400;const ctx=c.getContext('2d');ctx.scale(2,2);
    const angle=Math.PI/6,tx=90+39*Math.sin(angle),ty=39*Math.cos(angle);
    const startY = retry ? 116 : 187, curveY = retry ? 101 : 157;
    ctx.strokeStyle='#fff';ctx.lineCap='round';ctx.lineJoin='round';ctx.lineWidth=2;ctx.beginPath();ctx.moveTo(124,startY);ctx.bezierCurveTo(173,curveY,tx+29,ty+51,tx,ty);ctx.stroke();
    ctx.globalAlpha=.32;ctx.lineWidth=1;ctx.beginPath();ctx.moveTo(123,startY+1);ctx.bezierCurveTo(171,curveY+2,tx+31,ty+53,tx,ty);ctx.stroke();
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
      if (p >= 1) setPhase('orbit', orbitSeconds, now);
    } else if (phase === 'orbit') {
      view = { ...restingView('connected'), zoom: 0, glow: .2 + .08 * Math.sin(t), pose: orbit(p) };
      if (p >= 1) {
        if (logicalState === 'connected') {
          view.pose.yaw -= Math.PI * 2;
          transitionFrom = view;
          setPhase('arrive', .58, now);
        } else {
          setPhase('orbit', orbitSeconds, now);
        }
      }
    } else if (phase === 'arrive') {
      view = blendView(transitionFrom, restingView('connected'), s);
      if (p >= 1) setPhase('connected', 1, now);
    } else if (phase === 'return') {
      view = blendView(transitionFrom, restingView('idle'), s);
      if (p >= 1) setPhase('idle', 1, now);
    } else if (phase === 'error') {
      view = transitionFrom ? blendView(transitionFrom, restingView('error'), s) : restingView('error');
    } else view = restingView(logicalState);
    if (settings.motion && ['idle', 'error'].includes(phase)) {
      view.pose.y += Math.sin(t * .9) * .65;
      view.pose.roll += phase === 'error' ? Math.sin(t * .85) * .035 : Math.sin(t * .65) * .018;
    }
    lastView = view;
    const inFlight = settings.motion && ['launch', 'orbit', 'arrive', 'return'].includes(phase);
    const b = layout(view.zoom);
    if (now - lastSpacePaint >= 100 || !settings.motion) {
      drawSpace(t); lastSpacePaint = now;
    }
    const haloState = [b.d, b.cy, view.glow, view.error].join('/');
    if (haloState !== haloKey) { drawHalo(b, view); haloKey = haloState; }
    if (renderer) {
      earth.position.set(b.cx-w/2,h/2-b.cy,0);earth.scale.setScalar(b.d*.432);
      earth.rotation.set(.21,-1.77+t*Math.PI*2/100,-.08,'XYZ');
      earthUniforms.glow.value=view.glow;earthUniforms.error.value=view.error;
      for (const [kind, sprite] of Object.entries(sprites)) {
        const alpha = view.weights[kind], pose = view.pose;
        sprite.mesh.visible = alpha > .001 && !(inFlight && kind === 'flying');
        sprite.material.opacity = alpha;
        // Keep the approved face facing the viewer through the orbit.
        sprite.mesh.rotation.set(0,0,pose.roll);
        sprite.mesh.position.set(pose.x-w/2,h/2-pose.y,pose.z);
        sprite.mesh.scale.setScalar(pose.width);
        sprite.mesh.renderOrder = kind === 'flying' ? 2 : 3;
      }
      const pose = view.pose;
      flight.mesh.visible = inFlight && view.weights.flying > .001;
      if (flight.mesh.visible) {
        flight.mesh.position.set(pose.x - w / 2, h / 2 - pose.y, pose.z);
        flight.mesh.rotation.set(0, pose.yaw, pose.roll, 'ZYX');
        flight.mesh.scale.setScalar(pose.width);
        flight.mesh.renderOrder = 2;
        flight.uniforms.time.value = t;
        flight.materials.forEach(material => {
          material.opacity = view.weights.flying;
          material.depthWrite = view.weights.flying >= .995;
        });
      }
      renderer.render(world,camera);
    }
    // Error/retry controls follow the resting globe, not the departing flight.
    const resting = layout(0), hit = b.d*.86;
    Object.assign(power.style,{left:resting.cx+'px',top:resting.cy+'px'});
    Object.assign(hint.style,{left:resting.cx+'px',top:resting.cy+'px'});
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
    raf = 0;
    if (!ready || !hostReceived || !visible || !intersecting) return;
    if ((presented || resize()) &&
        ((presented && !settings.motion) || now - lastPaint >= 1000 / 30 - 1)) {
      lastPaint = now;
      draw(now);
      // A resize invalidates any frame Chromium prepared at the old viewport.
      if (!presented && ++stableFrames === 2) {
        main.dataset.startup = 'prepared';
        send('ready', String(layoutRevision));
      }
    }
    if ((!presented || settings.motion) && !raf) raf = requestAnimationFrame(frame);
    else if ((host.connected || host.connecting) && !stillTimer) {
      stillTimer = setTimeout(() => { stillTimer = 0; wake(); }, 500);
    }
  }

  function wake() {
    if (ready && hostReceived && !raf && visible && intersecting) {
      raf = requestAnimationFrame(frame);
    }
  }

  // The host calls this only after Android's visual state callback. Recheck
  // geometry because WebView can resize while that callback is in flight.
  function reveal(revision, nativeWidth, nativeHeight) {
    if (presented) return true;
    if (!visible || !intersecting || !resize() || stableFrames < 2 ||
        revision !== String(layoutRevision)) return false;
    // The viewport is in CSS pixels and may round to a whole CSS pixel.
    const ratio = devicePixelRatio || 1;
    const tolerance = ratio + 1;
    if (!(Math.abs(innerWidth * ratio - nativeWidth) <= tolerance &&
          Math.abs(innerHeight * ratio - nativeHeight) <= tolerance)) return false;
    presented = true;
    main.dataset.startup = 'visible';
    main.removeAttribute('aria-hidden');
    syncControls();
    return true;
  }
  function update(next) {
    const wasConnected = host.connected;
    const resumed = hostReceived && !host.active && next.active === true;
    host = {...host, ...next};
    hostReceived = true;
    const previousMotion=settings.motion;
    settings.motion=host.motion&&!mq.matches;
    main.dataset.motion = settings.motion ? 'on' : 'off';
    if(ready && (previousMotion !== settings.motion || (resumed && host.connected))){
      // A preference change must not replay an old success/error transition.
      transitionFrom=null;
      const state=connectionState();
      setPhase(state==='connecting'?'orbit':state==='disconnecting'?'idle':state,state==='connecting'?orbitSeconds:1);
      lastView=restingView(state);
    }
    if(host.connected){
      if(Number.isFinite(host.connectedAt)&&host.connectedAt>0)connectedAt=host.connectedAt;
      else if(!wasConnected)connectedAt=Date.now();
    }
    if(!host.connected&&!host.connecting){connectedAt=0;lastTimer='';timer.textContent='00:00';}
    translateControls();
    setMode();$('.dp-source-name').textContent=host.source || text('Источник VPN', 'VPN source');
    const response = $('.dp-response');
    response.hidden = !Number.isFinite(host.responseMs) || host.responseMs <= 0;
    if (!response.hidden) {
      const label = text('Отклик VPN', 'VPN response');
      const value = host.responseMs + text(' мс', ' ms');
      response.textContent = value;
      response.setAttribute('aria-label', label + ' · ' + value);
    }
    const message=$('.dp-message');message.hidden=!host.message;message.textContent=host.message;
    reconcile();updateTimer();visibilityChanged();lastPaint=-Infinity;wake();
  }
  function connect() {
    if (!power.disabled) send('connect');
  }
  window.DropoHome = {update, reveal};
  power.addEventListener('click', connect);
  earthAction.addEventListener('click', connect);
  cancel.addEventListener('click', () => { if (!cancel.hidden) send('cancel'); });
  disconnect.addEventListener('click', () => { if (!disconnect.disabled) send('disconnect'); });
  service.addEventListener('click',()=>{if(!service.disabled)send('mode','blocked_only');});
  all.addEventListener('click',()=>{if(!all.disabled)send('mode','all_traffic');});
  $('.dp-source-row').addEventListener('click',()=>{if(!$('.dp-source-row').disabled)send('sources');});
  $('.dp-services').addEventListener('click',()=>{if(!$('.dp-services').disabled)send('services');});
  $('.dp-message').addEventListener('click',()=>send('help'));
  $('.dp-response').addEventListener('click',()=>{if(!details.hidden)send('help');});
  function visibilityChanged(){
    visible=document.visibilityState!=='hidden'&&host.active;
    if(!visible||!intersecting){if(pausedAt===null)pausedAt=performance.now();if(raf)cancelAnimationFrame(raf);raf=0;clearTimeout(stillTimer);stillTimer=0;lastTick=null;}
    else if(pausedAt!==null){phaseStart+=performance.now()-pausedAt;pausedAt=null;lastTick=null;wake();}
  }
  document.addEventListener('visibilitychange',visibilityChanged);
  new IntersectionObserver(entries=>{intersecting=entries[0].isIntersecting;visibilityChanged();if(intersecting)wake();},{threshold:.01}).observe(root);
  mq.addEventListener('change',()=>update(host));
  function resize(force = false) {
    const rect = scene.getBoundingClientRect(), bounds = phone.getBoundingClientRect();
    const valid = Math.min(innerWidth, innerHeight, rect.width, rect.height, bounds.width, bounds.height) > 0;
    const ratio = devicePixelRatio || 1;
    const next = valid ? [innerWidth, innerHeight, rect.width, rect.height, bounds.width, bounds.height, ratio].join('/') : '';
    if (!force && next === geometry) return valid;
    geometry = next;
    layoutRevision++;
    stableFrames = 0;
    if (!presented) main.dataset.startup = 'loading';
    if (!valid) return false;

    w = rect.width; h = rect.height; dpr = Math.min(ratio, 1.5);
    haloKey = null; lastSpacePaint = -Infinity;
    spaceW = bounds.width; spaceH = bounds.height;
    haloCanvas.width = Math.round(w * dpr); haloCanvas.height = Math.round(h * dpr);
    halo.setTransform(dpr, 0, 0, dpr, 0, 0);
    spaceCanvas.width = Math.round(spaceW * dpr); spaceCanvas.height = Math.round(spaceH * dpr);
    space.setTransform(dpr, 0, 0, dpr, 0, 0); prepareNebula();
    if (renderer) {
      renderer.setPixelRatio(dpr);
      renderer.setSize(w, h, false);
      camera.left = -w / 2; camera.right = w / 2;
      camera.top = h / 2; camera.bottom = -h / 2;
      camera.updateProjectionMatrix();
    }
    details.style.top = (layout(1).cy + 116) + 'px';
    cancel.style.top = Math.min(h - 70, layout(0).cy + 195) + 'px';
    lastPaint = -Infinity;
    return true;
  }
  function viewportChanged() { resize(); wake(); }
  new ResizeObserver(viewportChanged).observe(scene);
  window.addEventListener('resize', viewportChanged);
  function loadImage(url){return new Promise((resolve,reject)=>{const im=new Image();im.onload=()=>resolve(im);im.onerror=()=>reject(new Error('Scene asset unavailable'));im.src=url;});}
  setMode();resize();syncControls();
  const fonts = document.fonts ? Promise.all([
    document.fonts.load('400 14px Inter').catch(() => []),
    document.fonts.load('500 34px Caveat').catch(() => []),
  ]) : Promise.resolve();
  const images = Promise.all(Object.entries(window.DropoArt).map(async ([key, url]) => [key, await loadImage(url)]));
  Promise.all([images, fonts]).then(([pairs]) => {
    initWorld(Object.fromEntries(pairs));ready=true;lastView=restingView(connectionState());
    setPhase(connectionState()==='connecting'?'idle':connectionState());reconcile();lastPaint=-Infinity;wake();
  }).catch(error=>{status.textContent=text('Не удалось запустить сцену', 'Could not load the scene');main.dataset.error=error.message;ready=false;if(raf)cancelAnimationFrame(raf);raf=0;send('failed');});
  canvas.addEventListener('webglcontextlost',event=>{event.preventDefault();if(raf)cancelAnimationFrame(raf);raf=0;ready=false;send('failed');});
  window.addEventListener('pagehide',()=>{if(raf)cancelAnimationFrame(raf);clearTimeout(stillTimer);renderer?.dispose();renderer?.forceContextLoss();});
})();

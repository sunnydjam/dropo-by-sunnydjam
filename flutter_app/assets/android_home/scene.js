// Bundled Android presentation. Native Flutter/CoreBridge is the sole connection authority.
(() => {
  const root=document.getElementById('dropo-motion-preview'),$=s=>root.querySelector(s);
  const phone=$('.dp-phone'),main=$('.dp-main'),sceneElement=$('.dp-scene');
  const powerButton=$('.dp-start'),powerSign=$('.dp-power'),earthAction=$('.dp-earth-action'),hint=$('.dp-hint');
  const cancel=$('.dp-cancel'),details=$('.dp-details'),rows=[...root.querySelectorAll('.dp-reveal-row')],status=$('.dp-status-text'),timer=$('.dp-session-time');
  const service=$('.dp-mode-service'),all=$('.dp-mode-all'),pill=$('.dp-mode-pill'),note=$('.dp-mode-note');

  const spaceCanvas=$('.dp-space'),space=spaceCanvas.getContext('2d'),haloCanvas=$('.dp-globe'),halo=haloCanvas.getContext('2d'),canvas=$('.dp-front');
  const mq=matchMedia('(prefers-reduced-motion: reduce)'),settings={flightSeconds:6,cameraSeconds:1.25,motion:!mq.matches};
  // This view owns presentation only. Flutter/core own consent, routing and VPN state.
  let host={connected:false,connecting:false,disconnecting:false,busy:true,enabled:false,canCancel:false,active:true,motion:true,mode:'blocked_only',source:'Источник VPN',message:'',error:false},receivedState=false;
  let mode='services';
  function send(action,value){globalThis.DropoScene?.postMessage(JSON.stringify({action,value}));}
  let phase='loading',phaseStart=performance.now(),duration=1,ready=false,connectedAt=0,raf=0,lastPaint=-Infinity;
  let visible=document.visibilityState!=='hidden'&&host.active,intersecting=true,pausedAt=null,stillTimer=0;
  let w=390,h=610,dpr=1,spaceW=390,spaceH=760,nebula=null,renderer,world,camera,earth,waiting,flying,takeoff,topView,bottomView,earthUniforms;
  let flightSeconds=6,cameraSeconds=1.25,lastTimer='',sceneClock=0,lastTick=null,lastView={zoom:0,glow:0,pose:null},offView=null;
  const assetUrls=window.DropoArt;
  const artInfo={"waiting":{"crop":[0.13636364,0.04066986,0.64035088,0.90191388],"aspect":1.40846824,"head":[0.14788206,0.34605658,0.008],"span":0.65881849},"flying":{"crop":[0.02472089,0.14593301,0.93859649,0.73763955],"aspect":0.78589635,"head":[0.1833941,0.16866952,0.19],"span":0.47028329},"takeoff":{"crop":[0.06379585,0.03827751,0.82137161,0.8708134],"aspect":1.06019417,"head":[0.16561428,0.26901468,0.075],"span":0.51362257},"top":{"crop":[0.02073365,0.13955343,0.9585327,0.70255183],"aspect":0.73294509,"head":[0.1313507,0.14832755,0.075],"span":0.44420107},"bottom":{"crop":[0.02472089,0.1108453,0.95614035,0.82854864],"aspect":0.86655546,"head":[0.15129529,0.22567674,0.075],"span":0.39628727},"bridge01":{"crop":[0.02874433,0.03530895,0.1412002,0.45018915],"aspect":1.275,"head":[0.14486164,0.31724926,0.075],"span":0.65908203,"image":"bridgeAtlas"},"bridge02":{"crop":[0.22743318,0.03152585,0.14372163,0.44766709],"aspect":1.24561404,"head":[0.1508962,0.3074149,0.075],"span":0.64588816,"image":"bridgeAtlas"},"bridge03":{"crop":[0.41805345,0.02395965,0.15128593,0.45018915],"aspect":1.19,"head":[0.18566753,0.29560823,0.075],"span":0.59446615,"image":"bridgeAtlas"},"bridge04":{"crop":[0.61472516,0.02269862,0.15279879,0.44388399],"aspect":1.16171617,"head":[0.19384281,0.29727883,0.075],"span":0.57688738,"image":"bridgeAtlas"},"bridge05":{"crop":[0.81341402,0.02395965,0.15733737,0.42875158],"aspect":1.08974359,"head":[0.20115679,0.25946617,0.075],"span":0.56166116,"image":"bridgeAtlas"},"bridge06":{"crop":[0.00907716,0.52080706,0.17750882,0.42622951],"aspect":0.96022727,"head":[0.16780724,0.22349646,0.075],"span":0.51105291,"image":"bridgeAtlas"},"bridge07":{"crop":[0.20877458,0.53089533,0.18053454,0.39470366],"aspect":0.87430168,"head":[0.17153219,0.20107319,0.075],"span":0.50554295,"image":"bridgeAtlas"},"bridge08":{"crop":[0.40645487,0.53467844,0.18356026,0.37957125],"aspect":0.82692308,"head":[0.15995886,0.16919548,0.075],"span":0.50272579,"image":"bridgeAtlas"},"bridge09":{"crop":[0.60413515,0.53215637,0.18456883,0.4148802],"aspect":0.8989071,"head":[0.1426304,0.21387187,0.075],"span":0.48603996,"image":"bridgeAtlas"},"bridge10":{"crop":[0.80383258,0.54098361,0.18557741,0.42370744],"aspect":0.91304348,"head":[0.13027561,0.24237867,0.075],"span":0.4719769,"image":"bridgeAtlas"}};
  const clamp=(x,a=0,b=1)=>Math.max(a,Math.min(b,x)),mix=(a,b,p)=>a+(b-a)*p;
  const smooth=x=>{const p=clamp(x);return p*p*p*(p*(p*6-15)+10);};
  const bez=(a,b,c,d,p)=>{const q=1-p;return{x:q*q*q*a.x+3*q*q*p*b.x+3*q*p*p*c.x+p*p*p*d.x,y:q*q*q*a.y+3*q*q*p*b.y+3*q*p*p*c.y+p*p*p*d.y};};
  function setMode(next){mode=next;service.setAttribute('aria-pressed',String(next==='services'));all.setAttribute('aria-pressed',String(next==='all'));pill.style.transform=next==='all'?'translateX(100%)':'translateX(0)';note.textContent=next==='all'?'Весь интернет-трафик через VPN; локальная сеть — напрямую':'Выбранные сервисы через VPN, остальное — напрямую';$('.dp-services-row').hidden=next==='all';}
  function announce(text){if(status.textContent!==text)status.textContent=text;}
  function controls(){
    cancel.hidden=!host.canCancel||!['launch','orbit'].includes(phase);
    earthAction.disabled=!ready||(!host.enabled&&!host.canCancel)||phase==='disconnecting';
    powerButton.disabled=!ready||!host.enabled||phase!=='idle';
    service.disabled=all.disabled=!host.enabled||!host.connected||phase!=='connected';
    $('.dp-disconnect').disabled=!host.enabled||!host.connected;
    $('.dp-source-row').disabled=!host.enabled;
    $('.dp-services').disabled=!host.enabled;
    earthAction.setAttribute('aria-label',host.connected?'Отключить VPN нажатием на Землю':host.canCancel?'Отменить подключение VPN':'Подключить VPN нажатием на Землю');
  }
  function state(next,seconds,now=performance.now()){
    phase=next;phaseStart=now;duration=Math.max(.01,seconds);main.dataset.phase=next;
    main.dataset.busy=String(host.busy||host.connecting||host.disconnecting);controls();
    if(next==='idle'){announce(host.error?'Не удалось подключиться':host.busy?'Подготавливаем VPN':'Не подключено');details.hidden=true;details.inert=true;}
    else if(next==='connected'){announce('VPN подключён');details.hidden=false;details.inert=false;}
    else if(next==='disconnecting'){announce(host.disconnecting?'Отключаем VPN':host.error?'Не удалось подключиться':'Возвращаемся');details.inert=true;}
    else if(['landing','reveal'].includes(next)&&host.connected)announce('VPN подключён');else announce('Подключаем VPN');
    wake();
  }
  function layout(zoom){const big=Math.min(322,w*.88);return{cx:w/2,cy:mix(Math.min(h*.48,h-278),Math.min(236,h-420),zoom),d:mix(big,Math.min(240,w*.66),zoom),big};}
  function seated(zoom){const b=layout(zoom),width=88*b.d/b.big,height=width*1132/802;return{x:b.cx,y:b.cy-b.d*.432-height*(.69-.5)+1,width,z:b.d*.56,yaw:-.12,roll:0,depth:1};}
  function orbit(p){
    const b=layout(0),a=Math.PI*.10+p*Math.PI*4,views=[flying,topView,bottomView,frameMap?.bridge08,frameMap?.bridge09,frameMap?.bridge10].filter(Boolean),bound=(views.length?Math.max(...views.map(view=>view.radius)):.68)+.05,fit=(w*.5-5-.66*(b.d*.432+16))/(.66*bound+.57),width=Math.min(90,w*.23,fit),body=width*bound,radius=b.d*.432+body+16;
    let turn=0;for(const rearPass of [Math.PI*1.5,Math.PI*3.5])turn+=smooth((a-(rearPass-.24))/.48)*Math.PI;
    return{x:b.cx+Math.cos(a)*radius*.66,y:b.cy-Math.cos(a)*radius*Math.sqrt(1-.66*.66),width,z:Math.sin(a)*radius,yaw:turn+Math.sin(a+.3)*.23,roll:Math.cos(a)*.12,depth:Math.sin(a)};
  }
  function hero(zoom){const b=layout(zoom),width=110*b.d/b.big;return{x:b.cx+b.d*.25,y:b.cy-b.d*.432-24,width,z:b.d*.65,yaw:-.10,roll:.24,depth:1};}
  function blend(a,b,p){const r={};for(const k of ['x','y','width','z','yaw','roll','depth'])r[k]=mix(a[k],b[k],p);return r;}
  const motionTiming={"newSpriteCount":10,"fps":30,"contourStepTargetPx":5,"launch":{"keys":["waiting","bridge01","bridge02","bridge03","bridge04","takeoff","bridge05","bridge06","bridge07","flying"],"rawOutlineStepsPx":[3.606,3.0,7.134,9.041,6.325,6.325,7.211,5.099,8.0],"weightedPathPx":55.7395,"knots":[0.0,0.06468577,0.11850758,0.24649734,0.40869147,0.52215781,0.63562415,0.76499568,0.85647517,1.0],"duration":1.65,"estimatedMaxStepPxAt30Fps":2.6392},"top":{"keys":["flying","bridge08","top"],"rawOutlineStepsPx":[7.616,6.325],"weightedPathPx":13.9403,"knots":[0.0,0.54631232,1.0],"rampRadians":0.365,"estimatedMaxStepPxAt30Fps":4.9994},"bottom":{"keys":["flying","bridge09","bridge10","bottom"],"rawOutlineStepsPx":[9.033,4.043,10.784],"weightedPathPx":23.8605,"knots":[0.0,0.37858444,0.54803099,1.0],"rampRadians":0.6247,"estimatedMaxStepPxAt30Fps":4.9997},"disconnectDuration":2};
  function launchPose(progress){
    const from=seated(0),to=orbit(0),b=layout(0),q=clamp((progress-.12)/.88),result=blend(from,to,smooth(q));
    const start=[from.x-b.cx,b.cy-from.y,from.z],end=[to.x-b.cx,b.cy-to.y,to.z],r0=Math.hypot(...start),r1=Math.hypot(...end),n0=start.map(v=>v/r0),n1=end.map(v=>v/r1);
    const epsilon=.0001,next=orbit(epsilon),velocity=[(next.x-to.x)/(epsilon*flightSeconds),-(next.y-to.y)/(epsilon*flightSeconds),(next.z-to.z)/(epsilon*flightSeconds)],seconds=motionTiming.launch.duration*.88;
    const c2=n1.map((v,i)=>v-velocity[i]/r1*seconds/3),one=1-q;
    const direction=n0.map((v,i)=>one*one*one*v+3*one*one*q*v+3*one*q*q*c2[i]+q*q*q*n1[i]),length=Math.hypot(...direction),radius=mix(r0,r1,smooth(q))+Math.sin(Math.PI*q)**2*12;
    result.x=b.cx+direction[0]/length*radius;result.y=b.cy-direction[1]/length*radius;result.z=direction[2]/length*radius;
    for(const key of ['yaw','roll','depth']){const endVelocity=(next[key]-to[key])/(epsilon*flightSeconds);result[key]=(2*q*q*q-3*q*q+1)*from[key]+(-2*q*q*q+3*q*q)*to[key]+(q*q*q-q*q)*seconds*endVelocity;}
    result.alignHead=true;result.headBlend=smooth((progress-.18)/.60);return result;
  }
  function panel(amount){const p=clamp(amount);details.inert=p<.99||!host.connected;details.hidden=p<=0;details.style.opacity=String(p);details.style.transform=`translateY(${mix(-42,0,smooth(p))}px)`;rows.forEach((row,i)=>{const r=smooth((p-i*.12)/(1-i*.12));row.style.opacity=String(r);row.style.transform=`translateY(${(1-r)*12}px)`;});}
  const stars=Array.from({length:156},(_,i)=>{const rand=n=>{const x=Math.sin(i*127.1+n*311.7+71.4)*43758.5453;return x-Math.floor(x);};return{x:rand(1),y:rand(2),layer:rand(3),r:.35+rand(4)*.8,phase:rand(5)*Math.PI*2};});
  function prepareNebula(){nebula=document.createElement('canvas');nebula.width=Math.ceil(spaceW+120);nebula.height=Math.ceil(spaceH+120);const n=nebula.getContext('2d');n.fillStyle='#030908';n.fillRect(0,0,nebula.width,nebula.height);const clouds=[[.15,.26,.85,'#10362f30'],[.91,.54,.78,'#16392a24'],[.2,.93,.64,'#15223b26']];for(const[x,y,r,color]of clouds){const radius=spaceW*r,g=n.createRadialGradient(nebula.width*x,nebula.height*y,0,nebula.width*x,nebula.height*y,radius);g.addColorStop(0,color);g.addColorStop(1,'#00000000');n.fillStyle=g;n.fillRect(0,0,nebula.width,nebula.height);}}
  function drawSpace(t){
    space.clearRect(0,0,spaceW,spaceH);if(nebula)space.drawImage(nebula,-60+Math.sin(t/44)*24,-60+Math.cos(t/57)*20);
    for(let i=0;i<stars.length;i++){const star=stars[i],speed=.35+star.layer*1.5,x=(star.x*spaceW+t*speed*.70+spaceW*3)%spaceW,y=(star.y*spaceH+t*speed*.27+spaceH*3)%spaceH,alpha=(.22+star.layer*.36)*(.72+.28*Math.sin(t*(.65+star.layer*.6)+star.phase));space.fillStyle=`rgba(${i%5===0?'157,206,226':'209,234,222'},${alpha})`;space.beginPath();space.arc(x,y,star.r,0,Math.PI*2);space.fill();if(i%37===0){space.strokeStyle=`rgba(217,238,241,${alpha*.4})`;space.lineWidth=.6;space.beginPath();space.moveTo(x-2.5,y);space.lineTo(x+2.5,y);space.moveTo(x,y-2.5);space.lineTo(x,y+2.5);space.stroke();}}
    const streak=(t+9)%23;if(streak<1.0){const p=streak,x=spaceW*.74-p*spaceW*.26,y=spaceH*.15+p*spaceH*.09,g=space.createLinearGradient(x,y,x+34,y-13);g.addColorStop(0,`rgba(199,228,225,${Math.sin(p*Math.PI)*.3})`);g.addColorStop(1,'#d1eeea00');space.strokeStyle=g;space.lineWidth=.8;space.beginPath();space.moveTo(x,y);space.lineTo(x+34,y-13);space.stroke();}
  }
  const textureSources=new WeakMap();
  function textureFor(T,image,kind){let source=textureSources.get(image);if(!source){source=new T.Texture(image);source.colorSpace=T.SRGBColorSpace;source.needsUpdate=true;textureSources.set(image,source);}const c=artInfo[kind].crop,texture=source.clone();texture.offset.set(c[0],1-c[1]-c[3]);texture.repeat.set(c[2],c[3]);texture.needsUpdate=true;return texture;}
  function createWaitingRig(T,image){
    const info=artInfo.waiting,aspect=info.aspect,tex=textureFor(T,image,'waiting'),rootGroup=new T.Group(),uniforms={time:{value:0},motion:{value:1},bored:{value:1}};
    const materials=[0,1].map(()=>new T.MeshBasicMaterial({map:tex,transparent:true,alphaTest:.008,depthWrite:false,side:T.DoubleSide,toneMapped:false}));
    materials.forEach((material,index)=>{material.customProgramCacheKey=()=>`droppo-rigid-idle-${index}`;material.onBeforeCompile=shader=>{
      shader.uniforms.dpTime=uniforms.time;shader.uniforms.dpMotion=uniforms.motion;
      shader.vertexShader='uniform float dpTime;uniform float dpMotion;varying vec2 dpUv;\n'+shader.vertexShader;
      shader.vertexShader=shader.vertexShader.replace('#include <uv_vertex>','#include <uv_vertex>\n dpUv=uv;');
      shader.fragmentShader='varying vec2 dpUv;\n'+shader.fragmentShader;
      const mask=index===0?'1.0-(1.0-smoothstep(.448,.456,p.y))*smoothstep(.285,.305,p.x)':'(1.0-smoothstep(.468,.478,p.y))*smoothstep(.285,.305,p.x)';
      shader.fragmentShader=shader.fragmentShader.replace('#include <map_fragment>',`#include <map_fragment>\n vec2 p=vec2(dpUv.x,1.0-dpUv.y);diffuseColor.a*=${mask};`);
      if(index===0)shader.vertexShader=shader.vertexShader.replace('#include <begin_vertex>',`#include <begin_vertex>
        vec2 p=vec2(uv.x,1.0-uv.y),knee=vec2(.765,.755),q=p-knee;
        float leg=smoothstep(.71,.83,p.y)*smoothstep(.62,.75,p.x),a=(.18*sin(dpTime*1.8)+.045*sin(dpTime*.67))*dpMotion*leg;
        p=knee+mat2(cos(a),sin(a),-sin(a),cos(a))*q;
        float cape=(1.0-smoothstep(.35,.55,p.x))*smoothstep(.45,.75,p.y);
        p.x+=sin(dpTime*1.25+p.y*8.0)*.012*cape*dpMotion;
        p.y+=sin(dpTime*1.5)*.002*smoothstep(.48,.60,p.y)*(1.0-smoothstep(.70,.9,p.y))*dpMotion;
        transformed.x=p.x-.5;transformed.y=(.5-p.y)*${aspect.toFixed(8)};
      `);
    };});
    const body=new T.Mesh(new T.PlaneGeometry(1,aspect,56,80),materials[0]);body.renderOrder=2;rootGroup.add(body);
    const pivot=new T.Group(),neck=new T.Vector3(.635-.5,(.5-.465)*aspect,.003);pivot.position.copy(neck);rootGroup.add(pivot);
    const head=new T.Mesh(new T.PlaneGeometry(1,aspect),materials[1]);head.position.copy(neck).multiplyScalar(-1);head.position.z=.008;head.renderOrder=3;head.userData.headLayer=true;pivot.add(head);
    world.add(rootGroup);return{mesh:rootGroup,material:materials[0],materials,uniforms,headPivot:pivot,head:info.head,span:info.span,aspect,radius:Math.hypot(.5,aspect*.5)};
  }
  function createSprite(T,image,kind){
    const info=artInfo[kind],aspect=info.aspect,tex=textureFor(T,image,kind);
    const geometry=new T.PlaneGeometry(1,aspect,56,80),material=new T.MeshBasicMaterial({map:tex,transparent:true,alphaTest:.008,depthWrite:false,side:T.DoubleSide,toneMapped:false});
    const uniforms={time:{value:0},bored:{value:0},motion:{value:1}};
    material.onBeforeCompile=shader=>{
      shader.uniforms.dpTime=uniforms.time;shader.uniforms.dpBored=uniforms.bored;shader.uniforms.dpMotion=uniforms.motion;
      shader.vertexShader=`uniform float dpTime;uniform float dpBored;uniform float dpMotion;\n`+shader.vertexShader;
      const deform=`
        vec2 p=vec2(uv.x,1.0-uv.y);
        float cape=(1.0-smoothstep(.20,.58,p.x))*smoothstep(.35,.7,p.y);
        transformed.y+=sin(dpTime*3.0+p.x*7.0)*.012*cape*dpMotion;
        transformed.z=.10*sin(p.x*3.14159265)+.035*sin(dpTime*1.5)*dpMotion;
      `;
      shader.vertexShader=shader.vertexShader.replace('#include <begin_vertex>','#include <begin_vertex>\n'+deform);
    };
    material.customProgramCacheKey=()=>`dropo-sprite-cloth-v2`;
    const mesh=new T.Mesh(geometry,material);mesh.renderOrder=4;world.add(mesh);return{mesh,material,uniforms,head:info.head,span:info.span,aspect,radius:Math.hypot(.5,aspect*.5,.12)};
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
  function initWorld(images){
    const T=globalThis.THREE;if(!T)throw new Error('3D engine unavailable');renderer=new T.WebGLRenderer({canvas,alpha:true,antialias:true,premultipliedAlpha:true,powerPreference:'low-power'});renderer.setClearColor(0,0);renderer.outputColorSpace=T.SRGBColorSpace;renderer.toneMapping=T.NoToneMapping;
    world=new T.Scene();camera=new T.OrthographicCamera(-w/2,w/2,h/2,-h/2,.1,2500);camera.position.z=1200;
    const map=new T.Texture(images.earth);map.needsUpdate=true;map.wrapS=T.RepeatWrapping;map.anisotropy=Math.min(4,renderer.capabilities.getMaxAnisotropy());
    earthUniforms={map:{value:map},glow:{value:0}};
    const earthMaterial=new T.ShaderMaterial({uniforms:earthUniforms,vertexShader:`varying vec2 texUv;varying vec3 viewNormal;void main(){texUv=uv;viewNormal=normalize(normalMatrix*normal);gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0);}`,fragmentShader:`
      uniform sampler2D map;uniform float glow;varying vec2 texUv;varying vec3 viewNormal;
      void main(){vec3 c=texture2D(map,texUv).rgb;float lum=dot(c,vec3(.2126,.7152,.0722));float gold=clamp((c.r-c.b-.031)/.216,0.,1.)*clamp((c.g-c.b-.012)/.176,0.,1.)*clamp((lum-.11)/.33,0.,1.);float terrain=mix(lum,min(lum,.106),gold);vec3 gray=vec3(.035+terrain*1.10);float g=max(c.g,.071+lum*1.12);vec3 green=mix(vec3(min(c.r,g*.74),g,min(c.b,g*.82)),c,gold);float facing=max(normalize(viewNormal).z,0.);float shading=.70+.30*pow(facing,.38);vec3 col=mix(gray,green,glow)*shading;float rim=pow(1.-facing,3.5);col+=mix(vec3(.10,.12,.12),vec3(.04,.29,.21),glow)*rim;gl_FragColor=vec4(col,1.);}
    `});
    earth=new T.Mesh(new T.SphereGeometry(1,128,80),earthMaterial);world.add(earth);
    waiting=createWaitingRig(T,images.waiting);flying=createFlyingVolume(T,images.flying,images.rear);takeoff=createSprite(T,images.takeoff,'takeoff');topView=createSprite(T,images.top,'top');bottomView=createSprite(T,images.bottom,'bottom');
    frameMap={waiting,flying,takeoff,top:topView,bottom:bottomView};
    for(let i=1;i<=10;i++){const key='bridge'+String(i).padStart(2,'0');frameMap[key]=createSprite(T,images.bridgeAtlas,key);}
    main.dataset.transitionSpriteCount='10';resize();
    renderer.compile(world,camera);const warmTarget=new T.WebGLRenderTarget(4,4);renderer.setRenderTarget(warmTarget);renderer.render(world,camera);renderer.setRenderTarget(null);warmTarget.dispose();main.dataset.spritesWarmed='true';
  }
  function drawHalo(b,glow,pose,seatAlpha){
    halo.clearRect(0,0,w,h);const r=b.d*.432,g=halo.createRadialGradient(b.cx,b.cy,r*.97,b.cx,b.cy,r*1.10);const color=glow>.01?`103,${Math.round(mix(167,232,glow))},${Math.round(mix(165,191,glow))}`:'191,204,199';g.addColorStop(0,`rgba(${color},0)`);g.addColorStop(.35,`rgba(${color},${mix(.11,.24,glow)})`);g.addColorStop(1,`rgba(${color},0)`);halo.fillStyle=g;halo.beginPath();halo.arc(b.cx,b.cy,r*1.1,0,Math.PI*2);halo.fill();
    if(seatAlpha>.01){halo.fillStyle=`rgba(0,0,0,${seatAlpha*.28})`;halo.beginPath();halo.ellipse(b.cx,b.cy-r+5,r*.18,4,0,0,Math.PI*2);halo.fill();}
  }
  function setSprite(sprite,pose,alpha,kind,t,bored){
    const mesh=sprite.mesh;mesh.visible=alpha>.001;if(!mesh.visible)return;
    let x=pose.x,y=pose.y,z=pose.z,width=pose.width;
    mesh.rotation.set(kind==='flying'?-.04:0,pose.yaw,pose.roll,'YXZ');
    if(pose.alignHead){
      const T=globalThis.THREE,common=new T.Vector3().fromArray(waiting.head).lerp(new T.Vector3().fromArray(flying.head),pose.headBlend),span=mix(waiting.span,flying.span,pose.headBlend);
      width=pose.width*(pose.headScale===false?1:span/sprite.span);
      const target=common.multiplyScalar(pose.width).applyEuler(new T.Euler(-.04*pose.headBlend,pose.yaw,pose.roll,'YXZ'));
      const own=new T.Vector3().fromArray(sprite.head).multiplyScalar(width).applyEuler(mesh.rotation);target.sub(own);x+=target.x;y-=target.y;z+=target.z;
    }
    if(sprite.volume){
      const b=layout(lastViewForRender),dx=x-b.cx,dy=b.cy-y,length=Math.hypot(dx,dy,z),safe=b.d*.432+width*(sprite.radius+.05)+10;
      if(length<safe){const ratio=safe/Math.max(.01,length);x=b.cx+dx*ratio;y=b.cy-dy*ratio;z*=ratio;}
      minimumClearance=Math.min(minimumClearance,Math.hypot(x-b.cx,b.cy-y,z)-b.d*.432-width*(sprite.radius+.05));
    }
    mesh.position.set(x-w/2,h/2-y,z);mesh.scale.setScalar(width);
    for(const material of sprite.materials||[sprite.material]){material.opacity=alpha;material.color.setScalar(mix(.80,1,clamp((pose.depth+1)/2)));if(sprite.volume)material.depthWrite=alpha>.999;}
    sprite.uniforms.time.value=t;sprite.uniforms.motion.value=settings.motion?1:0;sprite.uniforms.bored.value=bored;
    if(sprite.headPivot){const active=settings.motion?bored:0;sprite.headPivot.rotation.set(0,Math.sin(t*.5)*.025*active,(Math.sin(t*.72)*.045+Math.sin(t*1.43)*.012)*active);}
  }
  function drawArrow(){
    const c=hint.querySelector('canvas');c.width=360;c.height=400;const ctx=c.getContext('2d');ctx.scale(2,2);
    const angle=Math.PI/6,tx=90+39*Math.sin(angle),ty=39*Math.cos(angle);
    ctx.strokeStyle='#fff';ctx.lineCap='round';ctx.lineJoin='round';ctx.lineWidth=2;ctx.beginPath();ctx.moveTo(124,187);ctx.bezierCurveTo(173,157,tx+29,ty+51,tx,ty);ctx.stroke();
    ctx.globalAlpha=.32;ctx.lineWidth=1;ctx.beginPath();ctx.moveTo(123,188);ctx.bezierCurveTo(171,159,tx+31,ty+53,tx,ty);ctx.stroke();
    ctx.globalAlpha=1;ctx.lineWidth=2;ctx.beginPath();ctx.moveTo(tx-1,ty+18);ctx.quadraticCurveTo(tx+1,ty+7,tx,ty);ctx.quadraticCurveTo(tx+8,ty+7,tx+16,ty+9);ctx.stroke();
  }
  let lastViewForRender=0,minimumClearance=Infinity;
  let frameMap=null;const visitedBridgeFrames=new Set();
  const launchKeys=['waiting','bridge01','bridge02','bridge03','bridge04','takeoff','bridge05','bridge06','bridge07','flying'];
  const launchTimes=motionTiming.launch.knots;
  function frameOrder(sprite,order){sprite.mesh.traverse(object=>{if(object.isMesh)object.renderOrder=order+(object.userData.headLayer?1:0);});}
  function drawSequence(keys,progress,pose,t,bored,times=null){
    const u=clamp(progress),knots=times||keys.map((_,i)=>i/(keys.length-1));let index=0;while(index<keys.length-2&&u>=knots[index+1])index++;
    const f=clamp((u-knots[index])/(knots[index+1]-knots[index])),a=keys[index],b=keys[index+1];
    if(f<.999){frameOrder(frameMap[a],20);setSprite(frameMap[a],pose,1,a,t,bored);if(a.startsWith('bridge'))visitedBridgeFrames.add(a);}
    if(f>.001){frameOrder(frameMap[b],30);setSprite(frameMap[b],pose,f,b,t,bored);if(b.startsWith('bridge'))visitedBridgeFrames.add(b);}
  }
  function draw(now){
    if(lastTick!==null&&settings.motion)sceneClock+=Math.min(100,(now-lastTick))/1000;lastTick=now;const t=sceneClock;
    const p=settings.motion?clamp((now-phaseStart)/1000/duration):0,s=smooth(p),b0=layout(0);let zoom=0,glow=0,pose=seated(0),panelAmount=0,buttonAmount=0,hintAmount=0,flyAlpha=0,bored=0,takeoffAlpha=0,topAlpha=0,bottomAlpha=0,waitAlpha=null;
    if(['idle','loading'].includes(phase)){buttonAmount=1;hintAmount=1;bored=1;}
    else if(phase==='launch'){pose=launchPose(p);waitAlpha=1-smooth((p-.32)/.08);takeoffAlpha=smooth((p-.20)/.14)*(1-smooth((p-.78)/.10));flyAlpha=smooth((p-.60)/.18);bored=1-smooth(p/.30);glow=.1+.12*s;buttonAmount=1-smooth(p/.20);hintAmount=1-smooth(p/.16);if(p>=1)state('orbit',flightSeconds,now);}
    else if(phase==='orbit'){pose=orbit(p);pose.alignHead=true;pose.headBlend=1;pose.headScale=false;const a=Math.PI*.10+p*Math.PI*4,topDistance=Math.abs(Math.atan2(Math.sin(a-Math.PI*1.73),Math.cos(a-Math.PI*1.73))),bottomDistance=Math.abs(Math.atan2(Math.sin(a-Math.PI*1.27),Math.cos(a-Math.PI*1.27))),topRamp=motionTiming.top.rampRadians*6/flightSeconds,bottomRamp=motionTiming.bottom.rampRadians*6/flightSeconds;topAlpha=smooth((.16+topRamp-topDistance)/topRamp);bottomAlpha=smooth((.16+bottomRamp-bottomDistance)/bottomRamp);flyAlpha=1;glow=.25+.38*(.5+.5*Math.sin((now-phaseStart)/700));if(p>=1)state(host.connected?'approach':'orbit',host.connected?1.10:flightSeconds,now);}
    else if(phase==='approach'){const from=orbit(1),to=hero(0);to.yaw+=Math.round((from.yaw-to.yaw)/(Math.PI*2))*Math.PI*2;pose=blend(from,to,s);Object.assign(pose,bez(from,{x:from.x-5,y:from.y-20},{x:to.x+25,y:to.y-25},to,s));flyAlpha=1;glow=mix(.45,1,s);if(p>=1)state('landing',.35,now);}
    else if(phase==='landing'){glow=1;pose=hero(0);flyAlpha=1;pose.y+=Math.sin(p*Math.PI)*2;if(p>=1){state('reveal',cameraSeconds,now);}}
    else if(phase==='reveal'){zoom=s;glow=1;pose=hero(zoom);flyAlpha=1;panelAmount=smooth((p-.12)/.88);if(p>=1)state('connected',1,now);}
    else if(phase==='connected'){zoom=1;glow=1;pose=hero(1);flyAlpha=1;panelAmount=1;}
    else if(phase==='disconnecting'){zoom=offView.zoom*(1-smooth((p-.1)/.9));glow=offView.glow*(1-smooth(p/.9));panelAmount=offView.zoom*(1-smooth(p/.28));const from=offView.pose,to=seated(0);pose=blend(from,to,s);Object.assign(pose,bez(from,{x:Math.min(w-45,from.x+100),y:from.y-20},{x:to.x+105,y:to.y+80},to,s));flyAlpha=Math.max(offView.flyAlpha*(1-s),smooth(p/.2)*(1-smooth((p-.53)/.47)));bored=smooth((p-.8)/.2);buttonAmount=smooth((p-.75)/.25);hintAmount=smooth((p-.78)/.22);if(p>=1){state('idle',1,now);reconcile();}}
    const b=layout(zoom);if(settings.motion&&['idle','connected'].includes(phase)){const bob=Math.sin(t/5)*.65;b.cy+=bob;pose.y+=bob;pose.roll+=phase==='idle'?-.035+Math.sin(t*.55)*.018:Math.sin(t*.7)*.024;if(phase==='connected'){pose.y+=Math.sin(t*1.1)*2.2;pose.yaw+=Math.sin(t*.6)*.035;}else{pose.yaw+=Math.sin(t*.62)*.05;}}
    drawSpace(t);drawHalo(b,glow,pose,1-flyAlpha);
    if(renderer){
      lastViewForRender=zoom;const r=b.d*.432;earth.position.set(b.cx-w/2,h/2-b.cy,0);earth.scale.setScalar(r);earth.rotation.set(.21,-1.77+t*Math.PI*2/100,-.08,'XYZ');earthUniforms.glow.value=glow;
      for(const sprite of Object.values(frameMap))sprite.mesh.visible=false;
      if(phase==='launch'){const u=smooth((p-.10)/.80);pose.alignHead=true;pose.headBlend=u;drawSequence(launchKeys,u,pose,t,bored,launchTimes);}
      else if(phase==='orbit'){
        if(topAlpha>=bottomAlpha&&topAlpha>.001)drawSequence(['flying','bridge08','top'],topAlpha,pose,t,0,motionTiming.top.knots);
        else if(bottomAlpha>.001)drawSequence(['flying','bridge09','bridge10','bottom'],bottomAlpha,pose,t,0,motionTiming.bottom.knots);
        else{frameOrder(flying,20);setSprite(flying,pose,1,'flying',t,0);}
      }else if(phase==='disconnecting'){const u=1-smooth((p-.12)/.78);pose.alignHead=true;pose.headBlend=u;drawSequence(launchKeys,u,pose,t,bored,launchTimes);}
      else if(['idle','loading'].includes(phase)){frameOrder(waiting,20);setSprite(waiting,pose,1,'waiting',t,bored);}
      else{frameOrder(flying,20);setSprite(flying,pose,1,'flying',t,0);}
      renderer.render(world,camera);if(phase==='connected'&&Number.isFinite(minimumClearance)){main.dataset.minimumClearancePx=minimumClearance.toFixed(2);main.dataset.transitionFramesUsed=String(visitedBridgeFrames.size);}
    }
    lastView={zoom,glow,pose:{...pose},flyAlpha};
    Object.assign(powerButton.style,{left:b.cx+'px',top:b.cy+'px',opacity:String(buttonAmount),visibility:buttonAmount>.001?'visible':'hidden',pointerEvents:phase==='idle'&&host.enabled?'auto':'none',transform:`translate(-50%,-50%) scale(${mix(.88,1,buttonAmount)})`});powerSign.style.opacity=String(buttonAmount);
    Object.assign(hint.style,{left:b.cx+'px',top:b.cy+'px',opacity:String(hintAmount)});
    const hit=b.d*.86;Object.assign(earthAction.style,{left:(b.cx-hit/2)+'px',top:(b.cy-hit/2)+'px',width:hit+'px',height:hit+'px'});panel(panelAmount);
    if(connectedAt){const seconds=Math.floor(Math.max(0,Date.now()-connectedAt)/1000),value=String(Math.floor(seconds/60)).padStart(2,'0')+':'+String(seconds%60).padStart(2,'0');if(value!==lastTimer){timer.textContent=value;lastTimer=value;}}
  }
  function frame(now){raf=0;if(!visible||!intersecting||(!ready&&main.dataset.error))return;if(!settings.motion||now-lastPaint>=1000/30-1){lastPaint=now;draw(now);}if(settings.motion&&!raf)raf=requestAnimationFrame(frame);else if((phase==='connected'||host.connecting)&&!stillTimer)stillTimer=setTimeout(()=>{stillTimer=0;wake();},500);}
  function wake(){if(!raf&&visible&&intersecting)raf=requestAnimationFrame(frame);}
  function start(){
    if(!ready||phase!=='idle')return;
    if(!settings.motion){state(host.connected?'connected':'orbit',flightSeconds);return;}
    state('launch',motionTiming.launch.duration);
  }
  function disconnect(){
    if(!ready||['idle','loading','disconnecting'].includes(phase))return;
    if(!settings.motion){state('idle',1);return;}
    offView={...lastView,pose:lastView.pose?{...lastView.pose}:seated(lastView.zoom)};
    details.inert=true;state('disconnecting',motionTiming.disconnectDuration);
  }
  function reconcile(){
    if(!ready)return;
    if(host.disconnecting||(!host.connected&&!host.connecting)){disconnect();}
    else if(host.connected){
      if(!settings.motion)state('connected',1);
      else if(phase==='idle')state('connected',1);
    }else if(host.connecting){
      if(phase==='idle')start();
      else if(!['launch','orbit','disconnecting'].includes(phase))state('orbit',flightSeconds);
    }
    controls();
  }
  function activate(){
    if(!ready)return;
    if(host.canCancel&&!host.connected)send('cancel');
    else if(host.enabled)send('toggle');
  }
  function update(next){
    const wasConnected=host.connected;host={...host,...next};
    settings.motion=host.motion&&!mq.matches;
    if(host.connected&&!wasConnected)connectedAt=host.connectedAt||Date.now();
    if(!host.connected&&!host.connecting)connectedAt=0;
    setMode(host.mode==='all_traffic'?'all':'services');
    $('.dp-source-name').textContent=host.source;
    const message=$('.dp-message');message.hidden=!host.message;message.textContent=host.message;
    if(!receivedState&&ready){receivedState=true;state(host.connected?'connected':'idle',1);}
    reconcile();visibilityChanged();lastPaint=-Infinity;wake();
    if(phase==='idle')announce(host.error?'Не удалось подключиться':host.busy?'Подготавливаем VPN':'Не подключено');
  }
  window.DropoHome={update};
  powerButton.addEventListener('click',activate);earthAction.addEventListener('click',activate);
  cancel.addEventListener('click',()=>{if(host.canCancel)send('cancel');});
  $('.dp-disconnect').addEventListener('click',()=>{if(host.enabled&&host.connected)send('toggle');});
  service.addEventListener('click',()=>{if(host.enabled&&host.connected&&phase==='connected')send('mode','blocked_only');});
  all.addEventListener('click',()=>{if(host.enabled&&host.connected&&phase==='connected')send('mode','all_traffic');});
  $('.dp-source-row').addEventListener('click',()=>{if(host.enabled)send('sources');});
  $('.dp-services').addEventListener('click',()=>{if(host.enabled)send('services');});
  $('.dp-message').addEventListener('click',()=>send('help'));
  function visibilityChanged(){visible=document.visibilityState!=='hidden'&&host.active;if(!visible||!intersecting){if(pausedAt===null)pausedAt=performance.now();if(raf)cancelAnimationFrame(raf);raf=0;clearTimeout(stillTimer);stillTimer=0;lastTick=null;}else if(pausedAt!==null){const pause=performance.now()-pausedAt;phaseStart+=pause;pausedAt=null;lastTick=null;wake();}}
  document.addEventListener('visibilitychange',visibilityChanged);new IntersectionObserver(entries=>{intersecting=entries[0].isIntersecting;visibilityChanged();if(intersecting)wake();},{threshold:.01}).observe(root);
  mq.addEventListener('change',()=>update(host));
  function resize(){const rect=sceneElement.getBoundingClientRect();w=rect.width||390;h=rect.height||610;dpr=Math.min(devicePixelRatio||1,2);const phoneRect=phone.getBoundingClientRect();spaceW=phoneRect.width||390;spaceH=phoneRect.height||760;haloCanvas.width=Math.round(w*dpr);haloCanvas.height=Math.round(h*dpr);halo.setTransform(dpr,0,0,dpr,0,0);spaceCanvas.width=Math.round(spaceW*dpr);spaceCanvas.height=Math.round(spaceH*dpr);space.setTransform(dpr,0,0,dpr,0,0);prepareNebula();if(renderer){renderer.setPixelRatio(dpr);renderer.setSize(w,h,false);camera.left=-w/2;camera.right=w/2;camera.top=h/2;camera.bottom=-h/2;camera.updateProjectionMatrix();}details.style.top=(layout(1).cy+116)+'px';cancel.style.top=Math.min(h-70,layout(0).cy+195)+'px';lastPaint=-Infinity;wake();}
  new ResizeObserver(resize).observe(sceneElement);
  function loadImage(url){return new Promise((resolve,reject)=>{const im=new Image();im.onload=()=>resolve(im);im.onerror=()=>reject(new Error('Scene asset unavailable'));im.src=url;});}
  setMode(mode);drawArrow();resize();
  Promise.all(Object.entries(assetUrls).map(async([key,url])=>[key,await loadImage(url)])).then(pairs=>{initWorld(Object.fromEntries(pairs));ready=true;state(host.connected?'connected':'idle',1);reconcile();send('ready');lastPaint=-Infinity;wake();}).catch(error=>{announce('Не удалось запустить сцену');main.dataset.error=error.message;if(raf)cancelAnimationFrame(raf);raf=0;send('failed');});
  canvas.addEventListener('webglcontextlost',event=>{event.preventDefault();if(raf)cancelAnimationFrame(raf);raf=0;ready=false;announce('Сцена приостановлена');send('failed');});
  window.addEventListener('pagehide',()=>{if(raf)cancelAnimationFrame(raf);clearTimeout(stillTimer);renderer?.dispose();renderer?.forceContextLoss();});
})();

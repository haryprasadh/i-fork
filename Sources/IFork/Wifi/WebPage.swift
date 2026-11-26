enum WifiWebPage {
    static let html = #"""
    <!doctype html><html lang="en"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
    <title>iFork Wi-Fi Drop</title><style>
    :root{color-scheme:light dark;font-family:-apple-system,BlinkMacSystemFont,system-ui,sans-serif}
    *{box-sizing:border-box}body{margin:0;background:Canvas;color:CanvasText}
    main{max-width:600px;margin:auto;padding:24px 18px 60px}h1{font-size:28px;margin:8px 0 4px}
    p{opacity:.7;margin:0 0 24px}section{margin-top:28px}h2{font-size:18px;margin:0 0 14px}
    button,.pick{appearance:none;border:0;border-radius:14px;padding:16px 20px;font:600 17px system-ui;cursor:pointer}
    .pick{display:block;text-align:center;background:#1684f5;color:white;min-height:58px}
    .pick input{display:none}button{background:color-mix(in srgb,CanvasText 10%,Canvas);color:CanvasText}
    .row{display:flex;align-items:center;gap:12px;padding:13px 0;border-bottom:1px solid color-mix(in srgb,CanvasText 12%,Canvas)}
    .info{min-width:0;flex:1}.name{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:600}
    .meta{font-size:13px;opacity:.65;margin-top:3px}.row button{font-size:14px;padding:12px}
    progress{width:100%;height:7px;margin-top:8px;accent-color:#1684f5}#speed{font-size:14px;margin-top:12px;opacity:.7}
    .empty{opacity:.6;padding:12px 0}
    </style></head><body><main><h1>iFork Wi-Fi Drop</h1><p>Transfer files on your local network.</p>
    <section><label class="pick">Send to Mac<input id="picker" type="file" multiple></label>
    <div id="speed" aria-live="polite"></div><div id="uploads"></div></section>
    <section><h2>From Mac</h2><div id="files" class="empty">Loading…</div></section></main>
    <script>
    const key=new URLSearchParams(location.search).get('k')||'';
    const api=(path)=>path+(path.includes('?')?'&':'?')+'k='+encodeURIComponent(key);
    const format=(n)=>(n/1048576).toFixed(1)+' MB';
    const queue=[];let running=0;const speeds=new Map();
    document.querySelector('#picker').addEventListener('change',e=>{
      for(const file of e.target.files)queue.push(file);
      e.target.value='';pump();
    });
    function pump(){while(running<3&&queue.length){upload(queue.shift());}}
    function upload(file){
      running++;const id=crypto.randomUUID(),start=performance.now();
      const row=document.createElement('div');row.className='row';
      const info=document.createElement('div');info.className='info';
      const name=document.createElement('div');name.className='name';name.textContent=file.name;
      const meta=document.createElement('div');meta.className='meta';meta.textContent=format(file.size);
      const bar=document.createElement('progress');bar.max=100;bar.value=0;
      info.append(name,meta,bar);row.append(info);document.querySelector('#uploads').prepend(row);
      const xhr=new XMLHttpRequest();xhr.open('PUT',api('/upload?name='+encodeURIComponent(file.name)+'&size='+file.size));
      xhr.upload.onprogress=e=>{if(!e.lengthComputable)return;bar.value=e.loaded/e.total*100;
        const elapsed=Math.max((performance.now()-start)/1000,.1);
        speeds.set(id,{bytes:e.loaded,elapsed});updateSpeed();meta.textContent=format(e.loaded)+' / '+format(file.size);
      };
      xhr.onload=()=>{meta.textContent=xhr.status===201?'Sent · '+format(file.size):'Failed ('+xhr.status+')';bar.value=xhr.status===201?100:0;};
      xhr.onerror=()=>{meta.textContent='Connection lost';bar.value=0;};
      xhr.onloadend=()=>{running--;speeds.delete(id);updateSpeed();pump();};
      xhr.send(file);
    }
    function updateSpeed(){let rate=0;for(const s of speeds.values())rate+=s.bytes/s.elapsed;
      document.querySelector('#speed').textContent=running?running+' sending · '+format(rate)+'/s':'';
    }
    async function refresh(){try{
      const response=await fetch(api('/files'),{cache:'no-store'});if(!response.ok)throw Error();
      const files=await response.json(),box=document.querySelector('#files');box.replaceChildren();box.className='';
      if(!files.length){box.className='empty';box.textContent='No files shared yet';return;}
      for(const file of files){const row=document.createElement('div');row.className='row';
        const info=document.createElement('div');info.className='info';const name=document.createElement('div');name.className='name';name.textContent=file.name;
        const meta=document.createElement('div');meta.className='meta';meta.textContent=format(file.size);info.append(name,meta);
        const button=document.createElement('button');button.textContent='Download';button.onclick=()=>{location.href=api('/download/'+encodeURIComponent(file.id));};
        row.append(info,button);box.append(row);}
    }catch{document.querySelector('#files').textContent='Unable to load files';}}
    refresh();setInterval(refresh,2000);
    </script></body></html>
    """#
}

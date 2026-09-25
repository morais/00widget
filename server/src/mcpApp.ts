import { WEB_PREVIEW_RUNTIME, WEB_PREVIEW_STYLES } from "./guestPage";

/// Preview resource URI. The suffix is deliberately prerelease-shaped: MCP
/// hosts cache resources by URI, so an incompatible UI change gets a new URI
/// without changing either the stable or preview HTTP endpoint.
export const MCP_PREVIEW_RESOURCE_URI = "ui://00widget/preview/v1-preview.1.html";
export const MCP_APP_MIME_TYPE = "text/html;profile=mcp-app";

const APP_STYLES = `
:root{--bg:transparent;--card:color-mix(in srgb,Canvas 96%,CanvasText 4%);--fg:CanvasText;--muted:color-mix(in srgb,CanvasText 60%,transparent);--line:color-mix(in srgb,CanvasText 14%,transparent)}
body{display:block;padding:.75rem;background:transparent}
main{max-width:none}
.toolbar{display:flex;align-items:center;justify-content:space-between;gap:.75rem;margin:0 0 .75rem}
.toolbar h1{margin:0;font-size:.85rem}
.toolbar button{appearance:none;border:1px solid var(--line);border-radius:999px;background:var(--card);color:var(--fg);font:inherit;font-size:.8rem;font-weight:600;padding:.35rem .7rem;cursor:pointer}
.toolbar button:disabled{cursor:wait;opacity:.55}
.dashboard-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,20rem),1fr));gap:.75rem}
.dashboard-grid .card{margin:0}
#out>.card{max-width:26rem;margin:0 auto}
#out a.k{pointer-events:none;color:inherit;text-decoration:none}
`.trim();

// Standards-first MCP Apps bridge. `window.openai` is only a compatibility
// fallback for hosts that injected tool output before the bridge initialized.
const APP_SCRIPT = `
(function(){
  var out=document.getElementById('out');
  var refresh=document.getElementById('refresh');
  var pending=new Map();
  var nextId=1;
  var lastTool='';
  var lastArgs={};
  var observer=null;

  function post(message){window.parent.postMessage(message,'*')}
  function request(method,params){
    var id=nextId++;
    post({jsonrpc:'2.0',id:id,method:method,params:params||{}});
    return new Promise(function(resolve,reject){pending.set(id,{resolve:resolve,reject:reject})});
  }
  function notify(method,params){post({jsonrpc:'2.0',method:method,params:params||{}})}
  function showError(message){out.innerHTML='<p class="msg"></p>';out.firstChild.textContent=String(message||'Unable to load preview.')}
  function structured(result){return result&&result.structuredContent?result.structuredContent:result}
  function neutralizeLinks(){
    out.querySelectorAll('a').forEach(function(anchor){
      anchor.removeAttribute('href');
      anchor.setAttribute('aria-disabled','true');
      anchor.tabIndex=-1;
    });
  }
  function render(result){
    if(result&&result.isError){
      var failure=result.content&&result.content[0]&&result.content[0].text;
      showError(failure||'The preview could not be refreshed.');return
    }
    var data=structured(result);
    var renderer=globalThis.ZeroZeroPreview;
    if(!data||!renderer){showError('The preview returned no renderable data.');return}
    if(data.card){
      lastTool='render_card';
      lastArgs={id:data.card.id};
      out.innerHTML='<section class="card">'+renderer.renderCard(data.card)+'</section>';
    }else if(Array.isArray(data.cards)&&Array.isArray(data.activities)){
      lastTool='render_dashboard';
      lastArgs={};
      out.innerHTML=renderer.renderDashboard(data);
    }else{
      showError('The preview returned an unknown shape.');
    }
    neutralizeLinks();
  }
  function onMessage(event){
    if(event.source!==window.parent){return}
    var message=event.data;
    if(!message||message.jsonrpc!=='2.0'){return}
    if(message.id!=null&&pending.has(message.id)){
      var waiting=pending.get(message.id);pending.delete(message.id);
      if(message.error){waiting.reject(message.error)}else{waiting.resolve(message.result)}
      return;
    }
    if(message.method==='ui/notifications/tool-input'){
      var input=message.params&&message.params.arguments?message.params.arguments:message.params;
      if(input&&typeof input.id==='string'){lastArgs={id:input.id}}
      return;
    }
    if(message.method==='ui/notifications/tool-result'){
      render(message.params);
      return;
    }
    if(message.method==='ui/resource-teardown'){
      if(observer){observer.disconnect()}
      window.removeEventListener('message',onMessage);
      if(message.id!=null){post({jsonrpc:'2.0',id:message.id,result:{}})}
    }
  }
  window.addEventListener('message',onMessage,{passive:true});

  refresh.addEventListener('click',function(){
    if(!lastTool){return}
    refresh.disabled=true;
    bridgeReady.then(function(){return request('tools/call',{name:lastTool,arguments:lastArgs})}).then(render).catch(function(error){
      showError(error&&error.message?error.message:'Refresh failed.');
    }).finally(function(){refresh.disabled=false});
  });

  function observeSize(){
    if(typeof ResizeObserver==='function'){
      observer=new ResizeObserver(function(entries){
        var rect=entries[0]&&entries[0].contentRect;
        if(rect){notify('ui/notifications/size-changed',{width:Math.ceil(rect.width),height:Math.ceil(rect.height)})}
      });
      observer.observe(document.documentElement);
    }
  }

  var bridgeReady=request('ui/initialize',{
    appInfo:{name:'00widget-preview',version:'1.0.0-preview.1'},
    appCapabilities:{},
    protocolVersion:'2026-01-26'
  }).then(function(){
    notify('ui/notifications/initialized',{});
    refresh.disabled=false;
    observeSize();
    if(window.openai&&window.openai.toolOutput){render(window.openai.toolOutput)}
  }).catch(function(){
    if(window.openai&&window.openai.toolOutput){render(window.openai.toolOutput)}
    return false;
  });
})();
`.trim();

export function renderMcpAppHTML(): string {
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>00Widget preview</title>
<style>${WEB_PREVIEW_STYLES}\n${APP_STYLES}</style>
</head><body><main>
<div class="toolbar"><h1>00Widget preview</h1><button id="refresh" type="button" disabled>Refresh</button></div>
<div id="out"><p class="msg">Loading preview…</p></div>
</main><script>globalThis.ZeroZeroPreviewMode='mcp';</script><script>${WEB_PREVIEW_RUNTIME}</script><script>${APP_SCRIPT}</script></body></html>`;
}

export function mcpAppResource(origin: string) {
  const csp = {
    connectDomains: [] as string[],
    resourceDomains: [] as string[],
  };
  return {
    uri: MCP_PREVIEW_RESOURCE_URI,
    mimeType: MCP_APP_MIME_TYPE,
    text: renderMcpAppHTML(),
    _meta: {
      ui: { prefersBorder: false, csp, domain: origin },
      "openai/ui": { availableDisplayModes: ["inline", "fullscreen"] },
      "openai/widgetDescription": "A read-only rendering of current 00Widget state.",
      "openai/widgetPrefersBorder": false,
      "openai/widgetDomain": origin,
      "openai/widgetCSP": {
        connect_domains: [],
        resource_domains: [],
      },
    },
  };
}

export function mcpAppResourceDescriptor() {
  return {
    uri: MCP_PREVIEW_RESOURCE_URI,
    name: "00Widget preview",
    title: "00Widget preview",
    description: "Read-only preview of one card or the full dashboard.",
    mimeType: MCP_APP_MIME_TYPE,
  };
}

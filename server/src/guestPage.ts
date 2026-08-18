import { GUEST_LINK_PATH } from "./guestLinks";

// The browser fallback for a guest link. Only people *without* the app ever see
// it: /app/* is claimed in the apple-app-site-association, so on a device with
// 00Widget installed iOS routes the URL into the app instead of Safari.
//
// The token is in the fragment, so this page is served identically to everyone
// and the Worker never learns which link was opened. The script below reads
// location.hash and calls the API from the browser — same origin, so no CORS
// and no token in any request line the Worker logs.

const GUEST_STYLES = `
:root{color-scheme:light dark;--bg:#0f1115;--fg:#f5f7fa;--muted:#9aa3b2;--card:#171a21;--line:#252a34;--accent:#4da3ff}
@media (prefers-color-scheme:light){:root{--bg:#f6f7f9;--fg:#12151a;--muted:#5b6472;--card:#fff;--line:#e3e6ec}}
*{box-sizing:border-box}
body{margin:0;padding:2rem 1.25rem;background:var(--bg);color:var(--fg);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;display:flex;justify-content:center}
main{width:100%;max-width:26rem}
h1{font-size:1.05rem;font-weight:600;margin:0 0 1.25rem;color:var(--muted)}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:1.25rem;margin-bottom:1.25rem}
.title{font-size:1.25rem;font-weight:600;margin:0 0 .25rem}
.sub{color:var(--muted);margin:0 0 1rem}
.value{font-size:2.25rem;font-weight:700;letter-spacing:-.02em}
.unit{font-size:1rem;color:var(--muted);margin-left:.25rem}
.row{display:flex;justify-content:space-between;padding:.5rem 0;border-top:1px solid var(--line)}
.row .k{color:var(--muted)}
.spark{display:block;width:100%;height:64px;margin:.75rem 0}
.spark polyline{fill:none;stroke:var(--accent);stroke-width:1.5;stroke-linejoin:round;stroke-linecap:round}
.spark rect{fill:var(--accent)}
.spark rect.neg{fill-opacity:.45}
.spark line{stroke:var(--muted);stroke-width:1;stroke-dasharray:3 3}
.spark line.zero{stroke-dasharray:none}
.meta{color:var(--muted);font-size:.85rem;margin-top:1rem}
.msg{color:var(--muted);text-align:center;padding:2rem 0}
a.cta{display:block;text-align:center;background:var(--accent);color:#04101f;text-decoration:none;font-weight:600;padding:.85rem;border-radius:12px}
`.trim();

const GUEST_SCRIPT = `
(function(){
  var el=function(id){return document.getElementById(id)};
  var out=el('out');
  var token=location.hash.slice(1);
  // Same scaling rule as the iOS renderer: an explicit min/max pins the axis
  // and out-of-range points clamp; otherwise the series scales to itself.
  var spark=function(ch){
    var p=ch.points,n=p.length,w=100,ht=32;
    var lo=ch.min!=null?ch.min:Math.min.apply(null,p);
    var hi=ch.max!=null?ch.max:Math.max.apply(null,p);
    var anchors=[];
    if(ch.reference!=null){anchors.push(ch.reference)}
    if(ch.style==='delta'){anchors.push(0)}
    for(var a=0;a<anchors.length;a++){
      if(ch.min==null){lo=Math.min(lo,anchors[a])}
      if(ch.max==null){hi=Math.max(hi,anchors[a])}
    }
    var y=function(v){
      if(!(hi>lo)){return ht/2}
      var t=(v-lo)/(hi-lo);
      return ht-Math.max(0,Math.min(1,t))*ht;
    };
    var body='';
    var zero=(ch.style==='delta'&&lo<=0&&hi>=0)?y(0):null;
    if(ch.style==='bar'||ch.style==='delta'){
      var base=zero!=null?zero:ht;
      var bw=w/n*0.7;
      for(var i=0;i<n;i++){
        var top=y(p[i]);
        body+='<rect'+(top>base?' class="neg"':'')+' x="'+(i*w/n+(w/n-bw)/2).toFixed(2)+'" y="'+Math.min(base,top).toFixed(2)+'" width="'+bw.toFixed(2)+'" height="'+Math.max(0.6,Math.abs(top-base)).toFixed(2)+'"/>';
      }
    }else{
      var pts=[];
      for(var j=0;j<n;j++){pts.push((j*w/(n-1)).toFixed(2)+','+y(p[j]).toFixed(2))}
      body='<polyline points="'+pts.join(' ')+'" vector-effect="non-scaling-stroke"/>';
    }
    var ref='';
    if(zero!=null){
      ref+='<line class="zero" x1="0" x2="'+w+'" y1="'+zero.toFixed(2)+'" y2="'+zero.toFixed(2)+'" vector-effect="non-scaling-stroke"/>';
    }
    if(ch.reference!=null&&ch.reference>=lo&&ch.reference<=hi){
      var ry=y(ch.reference).toFixed(2);
      ref+='<line x1="0" x2="'+w+'" y1="'+ry+'" y2="'+ry+'" vector-effect="non-scaling-stroke"/>';
    }
    return '<svg class="spark" viewBox="0 0 '+w+' '+ht+'" preserveAspectRatio="none" aria-hidden="true">'+ref+body+'</svg>';
  };
  var esc=function(s){var d=document.createElement('div');d.textContent=s==null?'':String(s);return d.innerHTML};
  if(!token){out.innerHTML='<p class="msg">This link is missing its code. Open the original link or scan the QR code again.</p>';return}
  fetch('/v1/guest/resource',{headers:{authorization:'Bearer '+token}}).then(function(r){
    if(r.status===401){throw new Error('This link has expired or been revoked.')}
    if(!r.ok){throw new Error('This link is no longer available.')}
    return r.json()
  }).then(function(d){
    var h='';
    if(d.resourceKind==='card'){
      var c=d.card;
      h+='<p class="title">'+esc(c.title)+'</p>';
      if(c.subtitle){h+='<p class="sub">'+esc(c.subtitle)+'</p>'}
      if(c.value){h+='<div class="value">'+esc(c.value)+(c.unit?'<span class="unit">'+esc(c.unit)+'</span>':'')+'</div>'}
      if(c.chart&&c.chart.points&&c.chart.points.length>1){h+=spark(c.chart)}
      (c.items||[]).forEach(function(i){
        h+='<div class="row"><span class="k">'+esc(i.title)+'</span><span>'+esc(i.value||'')+' '+esc(i.unit||'')+'</span></div>'
      });
    } else {
      var a=d.activity;
      h+='<p class="title">'+esc(a.title)+'</p>';
      h+='<p class="sub">'+esc(a.state)+'</p>';
    }
    h+='<p class="meta">Shared with you. Read-only, and this link stops working on '+esc(new Date(d.expiresAt).toLocaleString())+'.</p>';
    out.innerHTML='<div class="card">'+h+'</div>';
  }).catch(function(e){
    out.innerHTML='<p class="msg">'+esc(e.message)+'</p>';
  });
})();
`.trim();

function renderGuestHTML(origin: string): string {
  return `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>Shared with you — 00Widget</title>
<style>${GUEST_STYLES}</style>
</head><body><main>
<h1>00Widget</h1>
<div id="out"><p class="msg">Loading…</p></div>
<a class="cta" href="${origin}/">Get 00Widget</a>
</main><script>${GUEST_SCRIPT}</script></body></html>`;
}

let cachedCsp: string | null = null;

async function guestContentSecurityPolicy(): Promise<string> {
  if (cachedCsp) return cachedCsp;
  const [scriptHash, styleHash] = await Promise.all([
    sha256Base64(GUEST_SCRIPT),
    sha256Base64(GUEST_STYLES),
  ]);
  // connect-src 'self' is what lets the inline script call /v1/guest/resource
  // and nothing else — the token in the fragment cannot be exfiltrated to
  // another origin by injected markup.
  cachedCsp = [
    "default-src 'none'",
    `style-src 'sha256-${styleHash}'`,
    `script-src 'sha256-${scriptHash}'`,
    "connect-src 'self'",
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'none'",
  ].join("; ");
  return cachedCsp;
}

async function sha256Base64(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return btoa(String.fromCharCode(...new Uint8Array(digest)));
}

export async function handleGuestPage(req: Request): Promise<Response> {
  const origin = new URL(req.url).origin;
  return new Response(renderGuestHTML(origin), {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "content-security-policy": await guestContentSecurityPolicy(),
      "permissions-policy": "camera=(), geolocation=(), microphone=()",
      // The URL fragment never reaches a server, but the page must not leak the
      // guest page's own address to whatever the visitor taps next either.
      "referrer-policy": "no-referrer",
      "strict-transport-security": "max-age=31536000; includeSubDomains",
      "x-content-type-options": "nosniff",
      "x-frame-options": "DENY",
      // Identical for every visitor — the token is client-side only — so this
      // is safely cacheable by anything in front of the Worker.
      "cache-control": "public, max-age=300",
    },
  });
}

export { GUEST_LINK_PATH };

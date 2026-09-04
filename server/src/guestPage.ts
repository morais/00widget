import { GUEST_LINK_PATH } from "./guestLinks";
import { esc } from "./html";
import type { Env } from "./types";

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
.producer{color:var(--muted);font-size:.85rem;margin:-.15rem 0 .6rem}
.sub{color:var(--muted);margin:0 0 1rem}
.value{font-size:2.25rem;font-weight:700;letter-spacing:-.02em}
.unit{font-size:1rem;color:var(--muted);margin-left:.25rem}
.cmp{font-size:.9rem;font-weight:600;color:var(--muted);margin:.2rem 0 0}
.cmp.sig-favorable{color:#34c759}
.cmp.sig-caution{color:#ff9f0a}
.cmp.sig-unfavorable{color:#ff3b30}
.cmp-label{color:var(--muted);font-weight:400;margin-left:.35rem}
.row{display:flex;justify-content:space-between;padding:.5rem 0;border-top:1px solid var(--line)}
.row .k{color:var(--muted)}
.spark{display:block;width:100%;height:64px;margin:.75rem 0}
.spark polyline{fill:none;stroke:var(--accent);stroke-width:1.5;stroke-linejoin:round;stroke-linecap:round}
.spark rect{fill:var(--accent)}
.spark rect.range{fill-opacity:.32}
.spark rect.s1{fill:#af52de}
.spark rect.s2{fill:#30b0c7}
.spark rect.s3{fill:#ff9f0a}
.spark rect.flow-inbound{fill:#30b0c7}.spark rect.flow-outbound{fill:#af52de}
.spark rect.sig-favorable{fill:#34c759}.spark rect.sig-neutral{fill:var(--muted)}
.spark rect.sig-caution{fill:#ff9f0a}.spark rect.sig-unfavorable{fill:#ff3b30}
.spark polyline.flow-inbound,.spark line.marker.flow-inbound,.spark line.metric-reference.flow-inbound{stroke:#30b0c7}
.spark polyline.flow-outbound,.spark line.marker.flow-outbound,.spark line.metric-reference.flow-outbound{stroke:#af52de}
.spark polyline.sig-favorable,.spark line.marker.sig-favorable,.spark line.metric-reference.sig-favorable{stroke:#34c759}
.spark polyline.sig-neutral,.spark line.marker.sig-neutral,.spark line.metric-reference.sig-neutral{stroke:var(--muted)}
.spark polyline.sig-caution,.spark line.marker.sig-caution,.spark line.metric-reference.sig-caution{stroke:#ff9f0a}
.spark polyline.sig-unfavorable,.spark line.marker.sig-unfavorable,.spark line.metric-reference.sig-unfavorable{stroke:#ff3b30}
.spark rect.role-forecast{fill-opacity:.48}.spark rect.role-baseline{fill-opacity:.55}
.spark rect.role-target{fill-opacity:.72}.spark rect.role-capacity{fill-opacity:.35}
.spark rect.role-remainder{fill-opacity:.45}.spark rect.period{fill-opacity:.1}
.spark polyline.role-forecast,.spark line.marker.role-forecast,.spark line.metric-reference.role-forecast{stroke-opacity:.48}
.spark polyline.role-baseline,.spark line.marker.role-baseline,.spark line.metric-reference.role-baseline{stroke-opacity:.55}
.spark polyline.role-target,.spark line.marker.role-target,.spark line.metric-reference.role-target{stroke-opacity:.72}
.spark polyline.role-capacity,.spark line.marker.role-capacity,.spark line.metric-reference.role-capacity{stroke-opacity:.35}
.spark polyline.role-remainder,.spark line.marker.role-remainder,.spark line.metric-reference.role-remainder{stroke-opacity:.45}
.spark line.metric-reference.role-baseline{stroke-dasharray:1 3}
.spark line.metric-reference.role-capacity{stroke-dasharray:6 2}
.spark rect.neg{fill-opacity:.45}
.spark line{stroke:var(--muted);stroke-width:1;stroke-dasharray:3 3}
.spark line.zero{stroke-dasharray:none}
.spark line.marker{stroke:var(--accent);stroke-width:1.5;stroke-dasharray:none;stroke-linecap:round}
.chart-legend,.chart-labels{display:flex;gap:.75rem;color:var(--muted);font-size:.75rem;margin:.25rem 0}
.chart-labels{justify-content:space-between}
.dot{display:inline-block;width:.5rem;height:.5rem;border-radius:50%;background:var(--accent);margin-right:.25rem}
.dot.s1{background:#af52de}.dot.s2{background:#30b0c7}.dot.s3{background:#ff9f0a}
.dot.flow-inbound{background:#30b0c7}.dot.flow-outbound{background:#af52de}
.dot.sig-favorable{background:#34c759}.dot.sig-neutral{background:var(--muted)}
.dot.sig-caution{background:#ff9f0a}.dot.sig-unfavorable{background:#ff3b30}
.dot.role-forecast{opacity:.48}.dot.role-baseline{opacity:.55}.dot.role-target{opacity:.72}
.dot.role-capacity{opacity:.35}.dot.role-remainder{opacity:.45}
.chart-legend small{opacity:.8}
.pips{display:flex;gap:3px;margin:.75rem 0}
.pip{flex:1;height:12px;border-radius:4px;background:var(--muted);opacity:.35}
.pip.g{background:#34c759;opacity:1}
.pip.w{background:#ff9f0a;opacity:1}
.pip.c{background:#ff3b30;opacity:1}
.pip.r{background:#0a84ff;opacity:1}
.bar{display:block;width:100%;height:16px;margin:.75rem 0}
.bar rect{fill:var(--accent);rx:4px}
.bar rect.g{fill:#34c759}
.bar rect.w{fill:#ff9f0a}
.bar rect.c{fill:#ff3b30}
.bar rect.r{fill:#0a84ff}
.bar rect.flow-inbound,.rank rect.flow-inbound{fill:#30b0c7}
.bar rect.flow-outbound,.rank rect.flow-outbound{fill:#af52de}
.bar rect.role-forecast,.rank rect.role-forecast{fill-opacity:.48}
.bar rect.role-baseline,.rank rect.role-baseline{fill-opacity:.55}
.bar rect.role-target,.rank rect.role-target{fill-opacity:.72}
.bar rect.role-capacity,.rank rect.role-capacity{fill-opacity:.35}
.bar rect.role-remainder,.rank rect.role-remainder{fill-opacity:.45}
.prog{display:block;width:100%;height:10px;margin:.75rem 0}
.prog rect.track{fill:var(--muted);fill-opacity:.22;rx:3px}
.prog rect.fill{fill:var(--accent);rx:3px}
.prog rect.fill.g{fill:#34c759}
.prog rect.fill.w{fill:#ff9f0a}
.prog rect.fill.c{fill:#ff3b30}
.prog rect.fill.r{fill:#0a84ff}
.prog rect.fill.sig-favorable{fill:#34c759}
.prog rect.fill.sig-neutral{fill:var(--muted)}
.prog rect.fill.sig-caution{fill:#ff9f0a}
.prog rect.fill.sig-unfavorable{fill:#ff3b30}
.state{color:var(--fg);font-weight:600;margin:0 0 .35rem}
.signal{color:var(--muted);font-size:.8rem;font-weight:500;margin-left:.35rem}
.rowsub{color:var(--muted);font-size:.85rem;margin:-.35rem 0 .35rem}
.item-semantic{color:var(--muted);font-size:.75rem;margin-left:.35rem}
.brief{padding:.65rem 0;border-top:1px solid var(--line)}
.brief:first-of-type{margin-top:.75rem}
.brief-label{font-size:.8rem;font-weight:700;color:var(--accent);margin:0 0 .15rem}
.brief-text{margin:0}
a.k{color:var(--accent);text-decoration:none}
a.k:hover{text-decoration:underline}
.rank{display:block;width:100%;height:4px;margin:-.15rem 0 .35rem}
.rank rect{fill:var(--accent);fill-opacity:.5;rx:2px}
.rank rect.g{fill:#34c759}.rank rect.w{fill:#ff9f0a}
.rank rect.c{fill:#ff3b30}.rank rect.r{fill:#0a84ff}
.meta{color:var(--muted);font-size:.85rem;margin-top:1rem}
.msg{color:var(--muted);text-align:center;padding:2rem 0}
a.cta{display:block;text-align:center;background:var(--accent);color:#04101f;text-decoration:none;font-weight:600;padding:.85rem;border-radius:12px}
`.trim();

const GUEST_SCRIPT = `
(function(){
  var el=function(id){return document.getElementById(id)};
  var out=el('out');
  var token=location.hash.slice(1);
  var SEM_SIGNAL={favorable:'sig-favorable',neutral:'sig-neutral',caution:'sig-caution',unfavorable:'sig-unfavorable'};
  var SEM_FLOW={inbound:'flow-inbound',outbound:'flow-outbound'};
  var SEM_ROLE={forecast:'role-forecast',baseline:'role-baseline',target:'role-target',capacity:'role-capacity',remainder:'role-remainder'};
  var SIGNAL_MARK={favorable:'✓',neutral:'•',caution:'!',unfavorable:'×'};
  var resolveSemantic=function(primary,fallback){
    primary=primary||{};fallback=fallback||{};
    return {role:primary.role||fallback.role,flow:primary.flow||fallback.flow,signal:primary.signal||fallback.signal};
  };
  var semanticClass=function(semantic){
    semantic=semantic||{};var classes=[];
    if(SEM_FLOW[semantic.flow]){classes.push(SEM_FLOW[semantic.flow])}
    if(SEM_SIGNAL[semantic.signal]){classes.push(SEM_SIGNAL[semantic.signal])}
    if(SEM_ROLE[semantic.role]){classes.push(SEM_ROLE[semantic.role])}
    return classes.join(' ');
  };
  var itemMeaning=function(item){
    var semantic=item.semantic||{},words=[];
    if(semantic.flow==='inbound'){words.push('↙ inbound')}
    if(semantic.flow==='outbound'){words.push('↗ outbound')}
    if(semantic.role){words.push(semantic.role)}
    return words.length?'<span class="item-semantic">'+esc(words.join(' · '))+'</span>':'';
  };
  var seriesSemantic=function(ch,series){return resolveSemantic(series.semantic,ch.semantic)};
  var seriesClass=function(ch,series,index){return ('s'+index+' '+semanticClass(seriesSemantic(ch,series))).trim()};
  var categoryBands=function(ch,n,w,ht){
    if(!ch.categories||ch.categories.length!==n){return ''}
    var slot=w/n,bands='';
    for(var i=0;i<n;i++){
      var cls=SEM_SIGNAL[ch.categories[i].signal];
      if(cls){bands+='<rect class="period '+cls+'" x="'+(i*slot).toFixed(2)+'" y="0" width="'+slot.toFixed(2)+'" height="'+ht+'"/>'}
    }
    return bands;
  };
  // Same scaling rule as the iOS renderer: an explicit min/max pins the axis
  // and out-of-range points clamp; otherwise the series scales to itself.
  var spark=function(ch){
    var p=ch.points,n=p.length,w=100,ht=32;
    var lo=ch.min!=null?ch.min:Math.min.apply(null,p);
    var hi=ch.max!=null?ch.max:Math.max.apply(null,p);
    if(ch.ranges&&ch.ranges.length){
      for(var ri=0;ri<ch.ranges.length;ri++){
        if(ch.min==null){lo=Math.min(lo,ch.ranges[ri].low)}
        if(ch.max==null){hi=Math.max(hi,ch.ranges[ri].high)}
      }
    }
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
    if(ch.style==='range'&&ch.ranges&&ch.ranges.length===n){
      var rangeSlot=w/n,rangeWidth=rangeSlot*0.56;
      for(var rr=0;rr<n;rr++){
        var lowY=y(ch.ranges[rr].low),highY=y(ch.ranges[rr].high);
        var rx=rr*rangeSlot+(rangeSlot-rangeWidth)/2;
        body+='<rect class="range '+semanticClass(ch.semantic)+'" x="'+rx.toFixed(2)+'" y="'+Math.min(lowY,highY).toFixed(2)+'" width="'+rangeWidth.toFixed(2)+'" height="'+Math.max(0.6,Math.abs(lowY-highY)).toFixed(2)+'"/>';
        if(ch.ranges[rr].value!=null){
          var markerY=y(ch.ranges[rr].value).toFixed(2),markerInset=rangeSlot*0.16;
          body+='<line class="marker '+semanticClass(ch.semantic)+'" x1="'+(rr*rangeSlot+markerInset).toFixed(2)+'" x2="'+((rr+1)*rangeSlot-markerInset).toFixed(2)+'" y1="'+markerY+'" y2="'+markerY+'" vector-effect="non-scaling-stroke"/>';
        }
      }
    }else if(ch.style==='bar'&&ch.series&&ch.series.length){
      var slot=w/n,group=slot*0.76;
      if(ch.stacking==='grouped'){
        var one=group/ch.series.length;
        for(var si=0;si<ch.series.length;si++){
          for(var gi=0;gi<n;gi++){
            var gy=y(ch.series[si].points[gi]);
            body+='<rect class="'+seriesClass(ch,ch.series[si],si)+'" x="'+(gi*slot+(slot-group)/2+si*one).toFixed(2)+'" y="'+gy.toFixed(2)+'" width="'+one.toFixed(2)+'" height="'+Math.max(0.6,ht-gy).toFixed(2)+'"/>';
          }
        }
      }else{
        var sums=[];for(var z=0;z<n;z++){sums.push(0)}
        for(var ss=0;ss<ch.series.length;ss++){
          for(var sj=0;sj<n;sj++){
            var lower=y(sums[sj]);sums[sj]+=ch.series[ss].points[sj];var upper=y(sums[sj]);
            body+='<rect class="'+seriesClass(ch,ch.series[ss],ss)+'" x="'+(sj*slot+(slot-group)/2).toFixed(2)+'" y="'+Math.min(lower,upper).toFixed(2)+'" width="'+group.toFixed(2)+'" height="'+Math.max(0.6,Math.abs(lower-upper)).toFixed(2)+'"/>';
          }
        }
      }
    }else if(ch.style==='bar'||ch.style==='delta'){
      var base=zero!=null?zero:ht;
      var bw=w/n*0.7;
      for(var i=0;i<n;i++){
        var top=y(p[i]);
        body+='<rect class="'+(top>base?'neg ':'')+semanticClass(ch.semantic)+'" x="'+(i*w/n+(w/n-bw)/2).toFixed(2)+'" y="'+Math.min(base,top).toFixed(2)+'" width="'+bw.toFixed(2)+'" height="'+Math.max(0.6,Math.abs(top-base)).toFixed(2)+'"/>';
      }
    }else{
      var pts=[];
      for(var j=0;j<n;j++){pts.push((j*w/(n-1)).toFixed(2)+','+y(p[j]).toFixed(2))}
      body='<polyline class="'+semanticClass(ch.semantic)+'" points="'+pts.join(' ')+'" vector-effect="non-scaling-stroke"/>';
    }
    var ref='';
    if(zero!=null){
      ref+='<line class="zero" x1="0" x2="'+w+'" y1="'+zero.toFixed(2)+'" y2="'+zero.toFixed(2)+'" vector-effect="non-scaling-stroke"/>';
    }
    if(ch.reference!=null&&ch.reference>=lo&&ch.reference<=hi){
      var ry=y(ch.reference).toFixed(2);
      var referenceSemantic=ch.referenceMetadata&&ch.referenceMetadata.semantic;
      ref+='<line class="metric-reference '+semanticClass(referenceSemantic)+'" x1="0" x2="'+w+'" y1="'+ry+'" y2="'+ry+'" vector-effect="non-scaling-stroke"/>';
    }
    var extra='';
    if(ch.referenceMetadata){
      var referenceSemantic=ch.referenceMetadata.semantic||{},referenceWords=[];
      if(referenceSemantic.role){referenceWords.push(referenceSemantic.role)}
      if(referenceSemantic.flow){referenceWords.push(referenceSemantic.flow)}
      if(referenceSemantic.signal){referenceWords.push(referenceSemantic.signal)}
      var referenceLabel=ch.referenceMetadata.label||referenceSemantic.role||referenceWords[0];
      if(referenceLabel){
        extra+='<div class="chart-legend"><span><i class="dot '+semanticClass(referenceSemantic)+'"></i>'+esc(referenceLabel)+(referenceWords.length?'<small> · '+esc(referenceWords.join(', '))+'</small>':'')+'</span></div>';
      }
    }
    if(ch.series&&ch.series.length){
      extra+='<div class="chart-legend">';
      for(var s=0;s<ch.series.length;s++){
        var semantic=seriesSemantic(ch,ch.series[s]),words=[];
        if(semantic.role){words.push(semantic.role)}
        if(semantic.flow){words.push(semantic.flow)}
        if(semantic.signal){words.push(semantic.signal)}
        var arrow=semantic.flow==='inbound'?'↓':(semantic.flow==='outbound'?'↑':'');
        extra+='<span>'+arrow+'<i class="dot '+seriesClass(ch,ch.series[s],s)+'"></i>'+esc(ch.series[s].label)+(words.length?'<small> · '+esc(words.join(', '))+'</small>':'')+'</span>';
      }
      extra+='</div>';
    }else if(ch.semantic){
      var words=[];
      if(ch.semantic.role){words.push(ch.semantic.role)}
      if(ch.semantic.flow){words.push(ch.semantic.flow)}
      if(ch.semantic.signal){words.push(ch.semantic.signal)}
      var arrow=ch.semantic.flow==='inbound'?'↓':(ch.semantic.flow==='outbound'?'↑':'');
      if(words.length){extra+='<div class="chart-legend"><span>'+arrow+esc(words.join(', '))+'</span></div>'}
    }
    if(ch.categories&&ch.categories.length){
      var cpicks=ch.categories.length<=4?ch.categories:[ch.categories[0],ch.categories[Math.floor((ch.categories.length-1)/2)],ch.categories[ch.categories.length-1]];
      extra+='<div class="chart-labels">'+cpicks.map(function(category){var mark=SIGNAL_MARK[category.signal];return '<span>'+(mark?mark+' ':'')+esc(category.label)+(category.signal?' <small>'+esc(category.signal)+'</small>':'')+'</span>'}).join('')+'</div>';
    }else if(ch.labels&&ch.labels.length){
      var picks=ch.labels.length<=4?ch.labels:[ch.labels[0],ch.labels[Math.floor((ch.labels.length-1)/2)],ch.labels[ch.labels.length-1]];
      extra+='<div class="chart-labels">'+picks.map(function(label){return '<span>'+esc(label)+'</span>'}).join('')+'</div>';
    }
    return '<svg class="spark" viewBox="0 0 '+w+' '+ht+'" preserveAspectRatio="none" aria-hidden="true">'+categoryBands(ch,n,w,ht)+ref+body+'</svg>'+extra;
  };
  // Status names are mapped to fixed class names rather than interpolated:
  // esc() escapes text, not attribute values, and this lands in a class.
  var PIP={good:'g',finished:'g',warning:'w',paused:'w',critical:'c',running:'r'};
  var pips=function(items){
    var out='';
    for(var i=0;i<items.length;i++){out+='<span class="pip '+(PIP[items[i].status]||'')+'"></span>'}
    return '<div class="pips">'+out+'</div>';
  };
  // SVG rather than flex-with-inline-widths: the page's CSP allows one hashed
  // stylesheet and no inline styles, so per-segment sizing has to be an
  // attribute. Presentation attributes are not styles as far as CSP is
  // concerned; a style="" would simply be dropped and every segment would come
  // out the same width.
  var breakdown=function(items){
    var total=0,i;
    for(i=0;i<items.length;i++){total+=Math.max(0,items[i].amount||0)}
    if(!(total>0)){return ''}
    var w=100,ht=16,gap=0.8,n=items.length,avail=w-gap*(n-1),x=0,out='';
    for(i=0;i<n;i++){
      var sw=Math.max(0.8,avail*Math.max(0,items[i].amount||0)/total);
      var cls=PIP[items[i].status]||semanticClass(items[i].semantic);
      var op=cls?1:Math.max(0.22,Math.pow(0.72,i));
      out+='<rect class="'+cls+'" x="'+x.toFixed(2)+'" y="0" width="'+sw.toFixed(2)+'" height="'+ht+'" fill-opacity="'+op.toFixed(2)+'"/>';
      x+=sw+gap;
    }
    return '<svg class="bar" viewBox="0 0 '+w+' '+ht+'" preserveAspectRatio="none" aria-hidden="true">'+out+'</svg>';
  };
  // Mirrors DashboardCard.progressValue on the device: an explicit progress
  // wins on any template, and a progress card that sends none falls back to
  // parsing value, reading anything above 1 as a percentage. No backticks in
  // here: this whole script is a TypeScript template literal.
  var clamp01=function(n){return Math.max(0,Math.min(1,n))};
  var fraction=function(c){
    if(typeof c.progress==='number'){return clamp01(c.progress)}
    if(c.template!=='progress'){return null}
    // Number(), not parseFloat(): Swift's Double(_:) rejects a string that is
    // not wholly a number, and parseFloat would read "184 of 240" as 184 and
    // draw a bar at 1.84% where the device draws none.
    if(typeof c.value!=='string'||c.value===''){return null}
    var d=Number(c.value);
    return isFinite(d)?clamp01(d>1?d/100:d):null;
  };
  // Width has to be an attribute rather than a style — see the note on
  // breakdown() above.
  var progressBar=function(f,status,signal){
    var cls=status?(PIP[status]||''):(SEM_SIGNAL[signal]||'');
    return '<svg class="prog" viewBox="0 0 100 10" preserveAspectRatio="none" aria-hidden="true">'
      +'<rect class="track" x="0" y="0" width="100" height="10"/>'
      +'<rect class="fill '+cls+'" x="0" y="0" width="'+(f*100).toFixed(2)+'" height="10"/></svg>';
  };
  // Who published the card, on its own line under the title, as the app and
  // Apple TV draw it. The producer's icon is dropped: it names an SF Symbol,
  // which a browser has no way to resolve — the same reason this page already
  // ignores a card's own icon and statusIcon. The label carries it alone.
  var producerLine=function(p){
    if(!p||!p.label){return ''}
    return '<p class="producer">'+esc(p.label)+'</p>';
  };
  // The change under the headline. Coloured by what the producer said the
  // change *means*, never by the sign of the number: "+18" is favorable for
  // trials and unfavorable for errors, and only the signal tells them apart.
  //
  // The class comes from the fixed SEM_SIGNAL map rather than from the signal
  // itself, because esc() escapes text and not attribute values — an
  // interpolated signal would be an attribute-injection foothold on the one
  // page that holds a guest token. An unrecognised signal simply gets no class
  // and draws muted, which is also what neutral does.
  var comparisonLine=function(cmp){
    if(!cmp||!cmp.value){return ''}
    var mark=SIGNAL_MARK[cmp.signal];
    return '<p class="cmp '+(SEM_SIGNAL[cmp.signal]||'')+'">'
      +(mark?esc(mark)+' ':'')+esc(cmp.value)
      +(cmp.label?'<span class="cmp-label">'+esc(cmp.label)+'</span>':'')
      +'</p>';
  };
  // Text-node serialization escapes &, < and >, and NOT quotes — a text node
  // never needs them escaped. Every use of esc() below is text context except
  // the anchor's href, which is why that one is built through the DOM instead:
  // see link() and the note above it.
  var esc=function(s){var d=document.createElement('div');d.textContent=s==null?'':String(s);return d.innerHTML};
  // An item's deepLink is producer-supplied, and https is not the property that
  // matters here — a URL may legitimately contain a double quote, and zod's
  // z.url() stores what it was given rather than a normalised form. Built as an
  // element and serialized, so the value goes through an attribute setter that
  // cannot be escaped out of, rather than through string concatenation. The
  // page's CSP would refuse an injected handler either way; this is what stops
  // it being the only thing that does.
  var link=function(href,text){
    var a=document.createElement('a');
    a.className='k';
    a.setAttribute('href',href);
    a.setAttribute('rel','noopener noreferrer');
    a.textContent=text==null?'':String(text);
    return a.outerHTML;
  };
  if(!token){out.innerHTML='<p class="msg">This link is missing its code. Open the original link or scan the QR code again.</p>';return}
  fetch('/v1/guest/resource',{headers:{authorization:'Bearer '+token}}).then(function(r){
    if(r.status===401){throw new Error('This link has expired or been revoked.')}
    if(!r.ok){throw new Error('This link is no longer available.')}
    return r.json()
  }).then(function(d){
    var h='';
    if(d.resourceKind==='card'){
      // No "Needs you" badge here, deliberately, and it is not an omission to
      // fix later. The badge is derived from an attention status *plus* an
      // action, and getGuestResource strips actions from a shared card — so
      // the second half is absent by design. It would be the wrong thing to
      // draw regardless: a guest is not the operator the badge addresses and
      // has nothing to press.
      var c=d.card;
      h+='<p class="title">'+esc(c.title)+'</p>';
      h+=producerLine(c.producer);
      if(c.subtitle){h+='<p class="sub">'+esc(c.subtitle)+'</p>'}
      if(c.value){h+='<div class="value">'+esc(c.value)+(c.unit?'<span class="unit">'+esc(c.unit)+'</span>':'')+'</div>'}
      h+=comparisonLine(c.comparison);
      var pf=fraction(c);
      if(pf!=null){h+=progressBar(pf,c.status)}
      if(c.chart&&c.chart.points&&c.chart.points.length>1){h+=spark(c.chart)}
      if(c.template==='history'&&(c.items||[]).length){h+=pips(c.items)}
      if(c.template==='breakdown'&&(c.items||[]).length){h+=breakdown(c.items)}
      if(c.template==='briefing'&&c.briefing){
        (c.briefing.sections||[]).forEach(function(s){
          h+='<div class="brief">'
            +(s.label?'<p class="brief-label">'+esc(s.label)+'</p>':'')
            +'<p class="brief-text">'+esc(s.text)+'</p></div>';
        });
      }
      var widest=0;
      (c.items||[]).forEach(function(i){if(i.amount!=null){widest=Math.max(widest,Math.max(0,i.amount))}});
      (c.items||[]).forEach(function(i){
        var label=i.deepLink
          ? link(i.deepLink,i.title)
          : '<span class="k">'+esc(i.title)+'</span>';
        h+='<div class="row"><span>'+label+itemMeaning(i)+'</span><span>'+esc(i.value||'')+' '+esc(i.unit||'')+'</span></div>';
        // Ranked against the widest row, matching the app. Width has to be an
        // attribute rather than a style — see the note on breakdown() above.
        if(widest>0&&i.amount!=null){
          h+='<svg class="rank" viewBox="0 0 100 4" preserveAspectRatio="none" aria-hidden="true"><rect class="'+(PIP[i.status]||semanticClass(i.semantic))+'" x="0" y="0" height="4" width="'+(Math.max(0,i.amount)/widest*100).toFixed(2)+'"/></svg>';
        }
      });
    } else {
      var a=d.activity;
      h+='<p class="title">'+esc(a.title)+'</p>';
      var signalMark=SIGNAL_MARK[a.signal];
      h+='<p class="state">'+(signalMark?esc(signalMark)+' ':'')+esc(a.state)
        +(a.signal?'<span class="signal">'+esc(a.signal)+'</span>':'')+'</p>';
      if(a.subtitle){h+='<p class="sub">'+esc(a.subtitle)+'</p>'}
      if(a.value){h+='<div class="value">'+esc(a.value)+(a.unit?'<span class="unit">'+esc(a.unit)+'</span>':'')+'</div>'}
      if(typeof a.progress==='number'){h+=progressBar(clamp01(a.progress),null,a.signal)}
      // Items suppress the chart here for the same reason they do on the Lock
      // Screen: rows and a plot are two stories and this is one card.
      var rows=(a.items||[]).filter(function(i){return i.status!=='finished'&&i.status!=='offline'});
      if(rows.length){
        rows.forEach(function(i){
          h+='<div class="row"><span><span class="k">'+esc(i.title)+'</span>'+itemMeaning(i)+'</span><span>'+esc(i.value||'')+' '+esc(i.unit||'')+'</span></div>';
          if(i.subtitle){h+='<p class="rowsub">'+esc(i.subtitle)+'</p>'}
          if(typeof i.progress==='number'){
            h+='<svg class="rank" viewBox="0 0 100 4" preserveAspectRatio="none" aria-hidden="true"><rect x="0" y="0" height="4" width="'+(clamp01(i.progress)*100).toFixed(2)+'"/></svg>';
          }
        });
      } else if(a.chart&&a.chart.points&&a.chart.points.length>1){
        h+=spark(a.chart);
      }
      if(a.endsAt){h+='<p class="sub">Ends '+esc(new Date(a.endsAt).toLocaleString())+'</p>'}
    }
    h+='<p class="meta">Shared with you. Read-only, and this link stops working on '+esc(new Date(d.expiresAt).toLocaleString())+'.</p>';
    out.innerHTML='<div class="card">'+h+'</div>';
  }).catch(function(e){
    out.innerHTML='<p class="msg">'+esc(e.message)+'</p>';
  });
})();
`.trim();

// Where the "Get 00Widget" button sends a visitor who does not have the app.
// Defaults to this deployment's own root, which is what a fork or a staging
// host should advertise; a deployment with a marketing site in front of the
// API points APP_DOWNLOAD_URL at it instead.
//
// Only http(s) is accepted: the value lands in an href, so a misconfigured
// `javascript:` URL would be a script-injection foothold on the one page that
// holds a guest token. Anything else falls back to the origin.
function appDownloadURL(env: Env, origin: string): string {
  const configured = env.APP_DOWNLOAD_URL?.trim();
  if (configured) {
    try {
      const url = new URL(configured);
      if (url.protocol === "https:" || url.protocol === "http:") return configured;
    } catch {
      // Fall through to the origin.
    }
  }
  return `${origin}/`;
}

function renderGuestHTML(ctaURL: string): string {
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
<a class="cta" href="${esc(ctaURL)}">Get 00Widget</a>
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

export async function handleGuestPage(req: Request, env: Env): Promise<Response> {
  const origin = new URL(req.url).origin;
  return new Response(renderGuestHTML(appDownloadURL(env, origin)), {
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

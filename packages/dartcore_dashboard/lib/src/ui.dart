import 'dart:convert';

/// The dashboard single-page UI: plain HTML, CSS and JavaScript with no
/// external requests (so it works offline and under a strict CSP). All
/// dynamic text is HTML-escaped before it is inserted into the page.
String dashboardHtml(String title, String basePath) {
  final safeTitle = const HtmlEscape().convert(title);
  final base = jsonEncode(basePath).replaceAll('<', r'<');
  return _template
      .replaceAll('__TITLE__', safeTitle)
      .replaceAll('"__BASE__"', base);
}

const _template = r'''<!doctype html>
<html lang="en" data-theme="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__ · DartCore Dashboard</title>
<style>
:root{--bg:#0b0e14;--panel:#0f131b;--panel2:#121722;--border:#1d2433;--text:#e7eaf0;--muted:#8b94a7;--accent:#2563eb;--accent-text:#fff;--good:#10b981;--good-bg:#0b2a22;--med:#eab308;--med-bg:#2e2708;--bad:#ef4444;--bad-bg:#331213;--row:#0d1119}
[data-theme=light]{--bg:#f5f6f8;--panel:#fff;--panel2:#f1f3f6;--border:#e2e6ee;--text:#12161f;--muted:#667085;--good-bg:#d9f5ea;--med-bg:#fbf1c9;--bad-bg:#fde0e0;--row:#fafbfc}
*{box-sizing:border-box}html,body{height:100%}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,sans-serif;display:flex}
aside{width:232px;flex:none;background:var(--panel);border-right:1px solid var(--border);display:flex;flex-direction:column;padding:18px 14px;gap:4px;position:sticky;top:0;height:100vh}
.brand{display:flex;align-items:center;gap:10px;font-size:20px;font-weight:700;padding:4px 8px 18px}
.brand svg{width:30px;height:30px}
nav a{display:flex;align-items:center;gap:12px;padding:10px 12px;border-radius:10px;color:var(--text);text-decoration:none;font-size:15px;cursor:pointer}
nav a:hover{background:var(--panel2)}nav a.active{background:var(--accent);color:var(--accent-text)}
nav svg{width:20px;height:20px;flex:none;opacity:.9}
.foot{margin-top:auto;color:var(--muted);font-size:12px;padding:8px}
main{flex:1;min-width:0;display:flex;flex-direction:column}
header{display:flex;align-items:center;gap:12px;padding:14px 28px;border-bottom:1px solid var(--border);background:var(--panel)}
header h2{margin:0;font-size:17px;font-weight:600}header .sp{flex:1}
select,input,button{font:inherit;color:var(--text);background:var(--panel2);border:1px solid var(--border);border-radius:9px;padding:8px 12px;outline:none}
button{cursor:pointer}button:hover{border-color:var(--muted)}
.content{padding:26px 28px 60px;max-width:1500px;width:100%}
h1{margin:0 0 18px;font-size:34px;font-weight:700;letter-spacing:-.5px}
.bar{display:flex;gap:0;margin-bottom:18px}.bar input{flex:1;max-width:520px;border-radius:9px 0 0 9px}.bar select{border-radius:0;border-left:0}.bar button{border-radius:0 9px 9px 0;border-left:0}
.card{background:var(--panel);border:1px solid var(--border);border-radius:12px;margin-bottom:22px;overflow:hidden}
.card>.hd{display:flex;align-items:center;gap:10px;padding:12px 18px;border-bottom:1px solid var(--border);color:var(--muted)}
.card>.hd select{border:0;background:transparent;color:var(--muted);padding:2px 4px}
.card>.bd{padding:14px 18px}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:16px;margin-bottom:22px}
.stat{background:var(--panel);border:1px solid var(--border);border-radius:12px;padding:16px 18px}
.stat .k{color:var(--muted);font-size:13px}.stat .v{font-size:28px;font-weight:700;margin-top:4px}.stat .s{color:var(--muted);font-size:12px;margin-top:2px}
table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:14px 18px;border-bottom:1px solid var(--border);white-space:nowrap}
th{color:var(--muted);font-weight:600;cursor:pointer;user-select:none}tbody tr:last-child td{border-bottom:0}tbody tr:hover{background:var(--row)}
td.num,th.num{text-align:right}.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:14px}
.m{font-weight:700;margin-right:8px}.GET{color:#38bdf8}.POST{color:#34d399}.PUT{color:#facc15}.PATCH{color:#fb923c}.DELETE{color:#f87171}.OPTIONS,.HEAD{color:#a78bfa}
.badge{display:inline-block;padding:3px 11px;border-radius:999px;font-size:13px;font-weight:600}
.b-Good{background:var(--good-bg);color:var(--good)}.b-Medium{background:var(--med-bg);color:var(--med)}.b-Bad{background:var(--bad-bg);color:var(--bad)}
.legend{display:flex;flex-wrap:wrap;gap:6px 22px;padding:6px 6px 2px;color:var(--muted);font-size:14px}.legend i{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:7px}
svg.chart{width:100%;height:auto;display:block}.axis{fill:var(--muted);font-size:11px}.grid{stroke:var(--border);stroke-dasharray:4 4}
.empty{padding:50px;text-align:center;color:var(--muted)}
.log{font-family:ui-monospace,Menlo,monospace;font-size:13px;padding:7px 18px;border-bottom:1px solid var(--border);display:flex;gap:12px;align-items:baseline}
.log .t{color:var(--muted);flex:none}.log .l{flex:none;width:58px;font-weight:700}.l-debug{color:var(--muted)}.l-info{color:#38bdf8}.l-warning{color:var(--med)}.l-error,.l-fatal{color:var(--bad)}
.log .msg{white-space:pre-wrap;word-break:break-word}
pre{margin:0;padding:14px 18px;background:var(--panel2);overflow:auto;font-size:12px;color:var(--muted);white-space:pre-wrap}
#login{position:fixed;inset:0;background:rgba(0,0,0,.6);display:none;align-items:center;justify-content:center;z-index:9}
#login .box{background:var(--panel);border:1px solid var(--border);border-radius:14px;padding:26px;width:min(420px,90vw)}
#login input{width:100%;margin:12px 0}#err{color:var(--bad);font-size:13px;min-height:18px}
@media(max-width:800px){aside{display:none}.content{padding:18px}}
</style>
</head>
<body>
<aside>
  <div class="brand"><svg viewBox="0 0 32 32" fill="none"><circle cx="16" cy="16" r="13" stroke="currentColor" stroke-width="2.5"/><path d="M9 20l5-6 4 4 5-8" stroke="#38bdf8" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/></svg>DartCore</div>
  <nav id="nav"></nav>
  <div class="foot">DartCore Dashboard<br>in-memory · per process</div>
</aside>
<main>
  <header>
    <h2 id="appname">__TITLE__</h2><span class="sp"></span>
    <select id="range"><option value="15m">Last 15 minutes</option><option value="1h" selected>Last hour</option><option value="6h">Last 6 hours</option><option value="24h">Last 24 hours</option></select>
    <select id="auto"><option value="0">Manual refresh</option><option value="5" selected>Auto 5s</option><option value="15">Auto 15s</option></select>
    <button id="refresh" title="Refresh">↻</button>
    <button id="theme" title="Toggle theme">◐</button>
    <button id="logout" title="Forget token">⎋</button>
  </header>
  <div class="content" id="view"></div>
</main>
<div id="login"><div class="box"><h3 style="margin:0">Dashboard token</h3>
  <p style="color:var(--muted);margin:6px 0 0">Enter the token configured for this dashboard. It is kept in this browser tab only.</p>
  <input id="tok" type="password" autocomplete="off" placeholder="token"><div id="err"></div>
  <button id="go" style="background:var(--accent);color:#fff;border:0;width:100%">Continue</button></div></div>
<script>
(function(){
"use strict";
var BASE = "__BASE__";
var COLORS = ["#3b82f6","#eab308","#06b6d4","#ec4899","#10b981","#6b7280"];
var ICONS = {
  dashboard:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg>',
  endpoints:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 18a8 8 0 1116 0"/><path d="M12 18l4-6"/></svg>',
  issues:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3l10 18H2z"/><path d="M12 10v5M12 18v.5"/></svg>',
  logs:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M6 3h9l4 4v14H6z"/><path d="M9 12h7M9 16h7"/></svg>'
};
var PAGES = [["dashboard","Dashboard"],["endpoints","Endpoints"],["issues","Issues"],["logs","Logs"]];
var state = {page:"dashboard", sort:{k:"total_ms", dir:-1}, metric:"total_time", search:"", method:"All", level:"", logSearch:"", openIssue:null};
var timer = null;

function esc(v){ return String(v==null?"":v).replace(/[&<>"']/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c];}); }
function $(id){ return document.getElementById(id); }
function fmtMs(ms){ if(ms>=1000){return (ms/1000).toFixed(ms>=10000?0:1)+"s";} if(ms>=10){return Math.round(ms)+"ms";} return ms.toFixed(1)+"ms"; }
function fmtN(n){ if(n>=1e6){return (n/1e6).toFixed(1)+"M";} if(n>=1e3){return (n/1e3).toFixed(1)+"k";} return String(n); }
function ago(iso){ var s=Math.max(0,(Date.now()-Date.parse(iso))/1000); if(s<60){return Math.round(s)+"s ago";} if(s<3600){return Math.round(s/60)+"m ago";} if(s<86400){return Math.round(s/3600)+"h ago";} return Math.round(s/86400)+"d ago"; }
function token(){ try{return sessionStorage.getItem("dc_token")||"";}catch(e){return "";} }

function api(path, params){
  var q = new URLSearchParams(Object.assign({range:$("range").value}, params||{})).toString();
  var h = {}; var t = token(); if(t){ h["Authorization"] = "Bearer "+t; }
  return fetch(BASE+"/api/"+path+"?"+q, {headers:h}).then(function(r){
    if(r.status===401){ showLogin(); throw new Error("unauthorized"); }
    if(!r.ok){ return r.json().then(function(j){ throw new Error(j.message||("HTTP "+r.status)); }); }
    return r.json();
  });
}
function showLogin(msg){ $("login").style.display="flex"; $("err").textContent = msg||""; $("tok").focus(); }

function chart(data){
  var W=1000,H=300,L=46,R=10,T=14,B=26, series=data.series||[];
  if(!series.length || !series[0].values.length){ return '<div class="empty">No traffic in this time range yet.</div>'; }
  var n=series[0].values.length, totals=[], i, s, max=0;
  for(i=0;i<n;i++){ var t=0; for(s=0;s<series.length;s++){ t+=series[s].values[i]; } totals.push(t); if(t>max){max=t;} }
  if(max===0){ return '<div class="empty">No traffic in this time range yet.</div>'; }
  var step=Math.pow(10,Math.floor(Math.log10(max))), top=Math.ceil(max/step)*step;
  if(top/step<2){ top=step*2; }
  function x(i){ return L+(n===1?0:i*(W-L-R)/(n-1)); }
  function y(v){ return T+(H-T-B)*(1-v/top); }
  var out='<svg class="chart" viewBox="0 0 '+W+' '+H+'" role="img" aria-label="chart">';
  for(i=0;i<=4;i++){ var gv=top*i/4, gy=y(gv); out+='<line class="grid" x1="'+L+'" x2="'+(W-R)+'" y1="'+gy+'" y2="'+gy+'"/><text class="axis" x="'+(L-8)+'" y="'+(gy+4)+'" text-anchor="end">'+(gv%1===0?gv:gv.toFixed(1))+'</text>'; }
  var base=new Array(n).fill(0);
  for(s=0;s<series.length;s++){
    var up=[], dn=[];
    for(i=0;i<n;i++){ up.push([x(i), y(base[i]+series[s].values[i])]); dn.push([x(i), y(base[i])]); }
    var d="M"+up.map(function(p){return p[0].toFixed(1)+","+p[1].toFixed(1);}).join("L")+"L"+dn.reverse().map(function(p){return p[0].toFixed(1)+","+p[1].toFixed(1);}).join("L")+"Z";
    out+='<path d="'+d+'" fill="'+COLORS[s%COLORS.length]+'" fill-opacity=".82" stroke="'+COLORS[s%COLORS.length]+'" stroke-width="1"/>';
    for(i=0;i<n;i++){ base[i]+=series[s].values[i]; }
  }
  for(i=0;i<=5;i++){ var idx=Math.round(i*(n-1)/5), ts=new Date(data.start+idx*data.bucket_ms); out+='<text class="axis" x="'+x(idx)+'" y="'+(H-6)+'" text-anchor="'+(i===0?"start":(i===5?"end":"middle"))+'">'+ts.toLocaleTimeString([], {hour:"2-digit",minute:"2-digit"})+'</text>'; }
  if(data.unit){ out+='<text class="axis" x="4" y="'+(T+4)+'">'+esc(data.unit)+'</text>'; }
  out+='</svg><div class="legend">'+series.map(function(se,k){return '<span><i style="background:'+COLORS[k%COLORS.length]+'"></i>'+esc(se.name)+'</span>';}).join("")+'</div>';
  return out;
}

function chartCard(){
  return '<div class="card"><div class="hd"><span>▤</span><select id="metric"><option value="total_time">Total time</option><option value="calls">Calls</option><option value="errors">Errors (5xx)</option></select></div><div class="bd" id="chart"><div class="empty">Loading…</div></div></div>';
}
function loadChart(){
  var el=$("metric"); if(el){ el.value=state.metric; el.onchange=function(){ state.metric=el.value; loadChart(); }; }
  return api("series",{metric:state.metric}).then(function(d){ var c=$("chart"); if(c){ c.innerHTML=chart(d); } });
}

function methodCell(e){ return '<span class="m '+esc(e.method)+' mono">'+esc(e.method)+'</span><span class="mono">'+esc(e.route)+'</span>'; }
function table(list){
  if(!list.length){ return '<div class="empty">No endpoints recorded in this time range.</div>'; }
  var k=state.sort.k, dir=state.sort.dir;
  list=list.slice().sort(function(a,b){ var av=a[k], bv=b[k]; if(typeof av==="string"){ return dir*av.localeCompare(bv); } return dir*(av-bv); });
  var cols=[["route","Endpoint",0],["calls","Calls",1],["typical_ms","Typical",1],["slow_ms","Slow",1],["awful_ms","Awful",1],["errors","5xx",1],["total_ms","Impact",1]];
  var h='<table><thead><tr>'+cols.map(function(c){ return '<th class="'+(c[2]?"num":"")+'" data-k="'+c[0]+'">'+c[1]+(state.sort.k===c[0]?(state.sort.dir<0?" ↓":" ↑"):" ↕")+'</th>'; }).join("")+'</tr></thead><tbody>';
  list.forEach(function(e){ h+='<tr><td>'+methodCell(e)+'</td><td class="num">'+fmtN(e.calls)+'</td><td class="num">'+fmtMs(e.typical_ms)+'</td><td class="num">'+fmtMs(e.slow_ms)+'</td><td class="num">'+fmtMs(e.awful_ms)+'</td><td class="num">'+(e.errors||"–")+'</td><td class="num"><span class="badge b-'+esc(e.impact)+'">'+esc(e.impact)+'</span></td></tr>'; });
  return h+'</tbody></table>';
}
function bindSort(){ var ths=document.querySelectorAll("th[data-k]"); for(var i=0;i<ths.length;i++){ ths[i].onclick=function(){ var k=this.getAttribute("data-k"); state.sort = state.sort.k===k ? {k:k,dir:-state.sort.dir} : {k:k,dir:-1}; render(); }; } }

var pages = {
  dashboard:function(){
    return Promise.all([api("summary"), api("endpoints")]).then(function(r){
      var s=r[0], eps=r[1];
      var html='<h1>Dashboard</h1><div class="stats">'
        +'<div class="stat"><div class="k">Requests</div><div class="v">'+fmtN(s.requests)+'</div><div class="s">'+s.requests_per_minute+' / min · '+s.endpoints+' endpoints</div></div>'
        +'<div class="stat"><div class="k">Error rate (5xx)</div><div class="v">'+(s.error_rate*100).toFixed(1)+'%</div><div class="s">'+s.errors+' failed requests</div></div>'
        +'<div class="stat"><div class="k">Typical / Slow</div><div class="v">'+fmtMs(s.typical_ms)+' <span style="font-size:15px;color:var(--muted)">/ '+fmtMs(s.slow_ms)+'</span></div><div class="s">median / 95th percentile</div></div>'
        +'<div class="stat"><div class="k">Open issues</div><div class="v">'+s.issues+'</div><div class="s">distinct errors since start</div></div></div>'
        +chartCard()+'<div class="card"><div class="hd">Top endpoints by total time</div>'+table(eps.slice(0,5))+'</div>';
      return {html:html, after:function(){ bindSort(); return loadChart(); }};
    });
  },
  endpoints:function(){
    return api("endpoints",{search:state.search, method:state.method}).then(function(eps){
      var html='<h1>Endpoints</h1><div class="bar"><input id="q" placeholder="Search endpoints..." value="'+esc(state.search)+'"><select id="m">'+["All","GET","POST","PUT","PATCH","DELETE"].map(function(m){return '<option'+(m===state.method?" selected":"")+'>'+m+'</option>';}).join("")+'</select><button id="goq">Go</button></div>'
        +chartCard()+'<div class="card">'+table(eps)+'</div>';
      return {html:html, after:function(){ bindSort(); var go=function(){ state.search=$("q").value; state.method=$("m").value; render(); }; $("goq").onclick=go; $("q").onkeydown=function(e){ if(e.key==="Enter"){go();} }; return loadChart(); }};
    });
  },
  issues:function(){
    return api("issues",{search:state.search}).then(function(list){
      var html='<h1>Issues</h1><div class="card">';
      if(!list.length){ html+='<div class="empty">No errors recorded. 🎉</div>'; }
      else{
        html+='<table><thead><tr><th>Error</th><th>Endpoint</th><th class="num">Count</th><th class="num">Last seen</th></tr></thead><tbody>';
        list.forEach(function(i){
          html+='<tr class="iss" data-id="'+esc(i.id)+'" style="cursor:pointer"><td><b>'+esc(i.type)+'</b><div style="color:var(--muted);white-space:normal;max-width:560px">'+esc(i.message)+'</div></td><td><span class="m '+esc(i.method)+' mono">'+esc(i.method)+'</span><span class="mono">'+esc(i.route)+'</span></td><td class="num">'+i.count+'</td><td class="num">'+esc(ago(i.last_seen))+'</td></tr>';
          if(state.openIssue===i.id){ html+='<tr><td colspan="4" style="padding:0"><pre>'+esc(i.stack||"(no stack trace)")+(i.request_ids.length?"\n\nRecent request ids: "+esc(i.request_ids.join(", ")):"")+'</pre></td></tr>'; }
        });
        html+='</tbody></table>';
      }
      return {html:html+'</div>', after:function(){ var rows=document.querySelectorAll("tr.iss"); for(var i=0;i<rows.length;i++){ rows[i].onclick=function(){ var id=this.getAttribute("data-id"); state.openIssue = state.openIssue===id?null:id; render(); }; } }};
    });
  },
  logs:function(){
    return api("logs",{level:state.level, search:state.logSearch}).then(function(list){
      var html='<h1>Logs</h1><div class="bar"><input id="q" placeholder="Search logs..." value="'+esc(state.logSearch)+'"><select id="lv">'+[["","All levels"],["debug","Debug+"],["info","Info+"],["warning","Warning+"],["error","Error+"]].map(function(l){return '<option value="'+l[0]+'"'+(l[0]===state.level?" selected":"")+'>'+l[1]+'</option>';}).join("")+'</select><button id="goq">Go</button></div><div class="card">';
      if(!list.length){ html+='<div class="empty">No log lines match.</div>'; }
      list.forEach(function(l){ html+='<div class="log"><span class="t">'+esc(new Date(l.time).toLocaleTimeString())+'</span><span class="l l-'+esc(l.level)+'">'+esc(l.level.toUpperCase())+'</span><span class="msg">'+esc(l.message)+(l.request_id?' <span style="color:var(--muted)">['+esc(l.request_id)+']</span>':'')+(l.error?'\n'+esc(l.error):'')+'</span></div>'; });
      return {html:html+'</div>', after:function(){ var go=function(){ state.logSearch=$("q").value; state.level=$("lv").value; render(); }; $("goq").onclick=go; $("q").onkeydown=function(e){ if(e.key==="Enter"){go();} }; }};
    });
  }
};

var rendering=false;
function render(){
  if(rendering){ return; } rendering=true;
  var a=document.activeElement, keep = a && a.id==="q" ? {v:a.value} : null;
  pages[state.page]().then(function(r){
    $("view").innerHTML=r.html;
    if(keep && $("q")){ $("q").value=keep.v; }
    return r.after && r.after();
  }).catch(function(e){ if(e.message!=="unauthorized"){ $("view").innerHTML='<div class="card"><div class="empty">Could not load data: '+esc(e.message)+'</div></div>'; } })
    .then(function(){ rendering=false; });
}
function nav(){
  $("nav").innerHTML=PAGES.map(function(p){ return '<a data-p="'+p[0]+'" class="'+(state.page===p[0]?"active":"")+'">'+ICONS[p[0]]+p[1]+'</a>'; }).join("");
  var as=document.querySelectorAll("nav a"); for(var i=0;i<as.length;i++){ as[i].onclick=function(){ go(this.getAttribute("data-p")); }; }
}
function go(p){ state.page=p; location.hash=p; nav(); render(); }
function schedule(){ if(timer){ clearInterval(timer); timer=null; } var s=parseInt($("auto").value,10); if(s>0){ timer=setInterval(function(){ if(!document.hidden && document.activeElement.tagName!=="INPUT"){ render(); } }, s*1000); } }

$("range").onchange=render; $("refresh").onclick=render; $("auto").onchange=schedule;
$("theme").onclick=function(){ var t=document.documentElement.getAttribute("data-theme")==="dark"?"light":"dark"; document.documentElement.setAttribute("data-theme",t); try{localStorage.setItem("dc_theme",t);}catch(e){} };
$("logout").onclick=function(){ try{sessionStorage.removeItem("dc_token");}catch(e){} showLogin(); };
$("go").onclick=function(){ var v=$("tok").value.trim(); if(!v){ $("err").textContent="Enter the token."; return; } try{sessionStorage.setItem("dc_token",v);}catch(e){} $("login").style.display="none"; $("tok").value=""; render(); };
$("tok").onkeydown=function(e){ if(e.key==="Enter"){ $("go").onclick(); } };
try{ var th=localStorage.getItem("dc_theme"); if(th){ document.documentElement.setAttribute("data-theme",th); } }catch(e){}
var h=(location.hash||"").replace("#",""); if(pages[h]){ state.page=h; }
nav(); schedule(); render();
})();
</script>
</body>
</html>
''';

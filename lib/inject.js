;(function(){
  'use strict';
  if(window.__czhtw)return;
  window.__czhtw=1;
  var DATA=JSON.parse(__CZHTW_DATA__);
  var D=new Map(Object.entries(DATA.d));
  var V=new Set(D.values());
  var T=DATA.t, BP=DATA.b.p, BS=DATA.b.s, BM=DATA.b.m;
  var RX=new Array(T.length);
  var MISS=new Set();
  // Never translate user content: chat messages, editors, code, terminals
  var SKIP='.ProseMirror,[contenteditable="true"],textarea,pre,code,.xterm,.cm-editor,.monaco-editor,'+
    '[data-testid^="conversation-turn"],[data-testid="user-message"],[data-testid="assistant-message"],'+
    '.font-claude-response,.standard-markdown,.progressive-markdown,.epitaxy-markdown,.markdown-document';
  function skipped(n){var el=n.nodeType===3?n.parentElement:n;return !!(el&&el.closest&&el.closest(SKIP));}
  function applyT(i,t){
    var re=RX[i];
    if(!re){try{re=RX[i]=new RegExp(T[i][0]);}catch(e){re=RX[i]=/(?!)/;}}
    var m=re.exec(t);
    if(!m)return;
    var r=T[i][1],out='';
    for(var k=0;k<r.length;k++)out+=typeof r[k]==='number'?m[r[k]]:r[k];
    return out;
  }
  function tryList(list,t){
    if(!list)return;
    for(var i=0;i<list.length;i++){var v=applyT(list[i],t);if(v!==undefined)return v;}
  }
  function lookup(t){
    var v=D.get(t);
    if(v!==undefined)return v;
    if(t.length>300||MISS.has(t))return;
    v=tryList(BP[t.slice(0,2)],t);
    if(v===undefined)v=tryList(BS[t.slice(-2)],t);
    if(v===undefined){
      for(var i=0;i<BM.length;i++){
        if(t.indexOf(BM[i][0])<0)continue;
        v=applyT(BM[i][1],t);
        if(v!==undefined)break;
      }
    }
    if(v===undefined){if(MISS.size>20000)MISS.clear();MISS.add(t);}
    return v;
  }
  function tr(s){
    if(!s||V.has(s))return;
    var v=lookup(s);
    if(v!==undefined)return v;
    var tt=s.trim();
    if(tt&&tt!==s&&!V.has(tt)&&(v=lookup(tt))!==undefined)return s.replace(tt,v);
  }
  // Reasoning effort levels stay in English. The effort pickers are server-driven (no stable
  // selector), so recognise them by content: a level next to a "Max" option, the "Effort" label
  // (or its translation) or a model name. Severity lists etc. still translate.
  var EFFORT=new Set(['Low','Medium','High','Extra','Extra high']);
  var EFFORT_ANCHOR=/^(Max|Effort|投入程度|(Claude )?(Opus|Sonnet|Haiku|Fable)( [\d.]+)?)$/;
  function hasAnchor(box){
    var w=document.createTreeWalker(box,4),n,count=0;
    while((n=w.nextNode())){
      if(++count>60)return false;
      if(EFFORT_ANCHOR.test(n.nodeValue.trim()))return true;
    }
    return false;
  }
  function effortLevel(node,t){
    if(!EFFORT.has(t.trim()))return false;
    var el=node.parentElement;
    var menu=el&&el.closest('[role="menu"],[role="listbox"],[role="radiogroup"]');
    if(menu&&hasAnchor(menu))return true;
    for(var i=0;i<3&&el;i++,el=el.parentElement){
      if(hasAnchor(el))return true;
    }
    return false;
  }
  function trText(node){
    var t=node.nodeValue;
    if(!t||V.has(t)||!/[A-Za-z]/.test(t))return;
    if(skipped(node)||effortLevel(node,t))return;
    var v=tr(t);
    if(v!==undefined&&v!==t)node.nodeValue=v;
  }
  var ATTRS=['placeholder','title','aria-label','aria-description'];
  function trAttrs(el){
    for(var i=0;i<ATTRS.length;i++){
      var a=el.getAttribute(ATTRS[i]);
      if(!a)continue;
      var v=tr(a);
      if(v!==undefined&&v!==a)el.setAttribute(ATTRS[i],v);
    }
  }
  function trEl(el){
    if(!el)return;
    var nt=el.nodeType;
    if(nt===3){trText(el);return;}
    if(nt!==1)return;
    var tag=el.tagName;
    if(tag==='SCRIPT'||tag==='STYLE')return;
    if(skipped(el))return;
    trAttrs(el);
    var w=document.createTreeWalker(el,5,{acceptNode:function(n){
      if(n.nodeType===1){
        var t=n.tagName;
        if(t==='SCRIPT'||t==='STYLE'||n.matches(SKIP))return 2;
        return 3;
      }
      return 1;
    }});
    var n;
    while((n=w.nextNode())){
      if(n.nodeType===3)trText(n);
    }
    var q=el.querySelectorAll('[placeholder],[title],[aria-label],[aria-description]');
    for(var i=0;i<q.length;i++)if(!skipped(q[i]))trAttrs(q[i]);
  }
  var queue=[],attrQueue=[],rafId=0;
  function flush(){
    rafId=0;
    var nodes=queue,attrs=attrQueue;
    queue=[];attrQueue=[];
    for(var i=0;i<nodes.length;i++)if(nodes[i].isConnected)trEl(nodes[i]);
    for(var j=0;j<attrs.length;j++)if(attrs[j].isConnected&&!skipped(attrs[j]))trAttrs(attrs[j]);
  }
  var obs=new MutationObserver(function(muts){
    for(var i=0;i<muts.length;i++){
      var m=muts[i];
      if(m.type==='characterData'){queue.push(m.target);continue;}
      if(m.type==='attributes'){attrQueue.push(m.target);continue;}
      var added=m.addedNodes;
      for(var j=0;j<added.length;j++)queue.push(added[j]);
    }
    if((queue.length||attrQueue.length)&&!rafId)rafId=requestAnimationFrame(flush);
  });
  function start(){
    if(!document.body){setTimeout(start,50);return;}
    trEl(document.body);
    obs.observe(document.body,{childList:true,subtree:true,characterData:true,attributes:true,attributeFilter:ATTRS});
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start);
  else start();
})();
